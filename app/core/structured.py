"""结构化输出兼容层.

统一使用 response_format={"type": "json_object"} + Pydantic 校验, 避免部分
OpenAI 兼容接口不支持 SDK Pydantic parse response_format.

校验失败时会重试 LLM 调用 (默认最多 3 次重试, 共 4 次), 全部失败后再抛异常,
由 Planner/Replanner/Router 等节点走 fallback.
"""

from __future__ import annotations

import json
import re
from typing import Any, TypeVar

from langchain_core.language_models import BaseChatModel
from loguru import logger
from pydantic import BaseModel, ValidationError

T = TypeVar("T", bound=BaseModel)

# 首次调用 + 重试次数 (共 STRUCTURED_MAX_ATTEMPTS 次 LLM 调用后才交给上层兜底)
STRUCTURED_MAX_ATTEMPTS = 3
STRUCTURED_RETRY_COUNT = STRUCTURED_MAX_ATTEMPTS - 1


def is_deepseek_model(model: str | None) -> bool:
    return bool((model or "").lower().startswith("deepseek"))


def _schema_hint(schema_cls: type[BaseModel]) -> str:
    schema = schema_cls.model_json_schema()
    props = schema.get("properties", {})
    required = set(schema.get("required", []))
    lines = []
    for name, meta in props.items():
        type_name = meta.get("type") or meta.get("anyOf") or "any"
        req = "必填" if name in required else "可选"
        desc = meta.get("description", "")
        lines.append(f'- "{name}" ({req}, {type_name}): {desc}')
    return "\n".join(lines)


def _extract_json(text: str) -> Any:
    raw = (text or "").strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*", "", raw, flags=re.IGNORECASE)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        match = re.search(r"(\{.*\}|\[.*\])", raw, flags=re.DOTALL)
        if not match:
            raise
        return json.loads(match.group(0))


def _coerce_parsed_data(data: Any, schema_cls: type[BaseModel]) -> dict[str, Any]:
    """把常见 LLM 格式偏差修成 object, 便于 Pydantic 校验."""
    if isinstance(data, dict):
        return data
    if isinstance(data, list):
        props = schema_cls.model_json_schema().get("properties", {})
        if "steps" in props:
            logger.warning(
                f"[structured] {schema_cls.__name__}: LLM 返回 json 数组, "
                '自动包装为 {"steps": [...]}'
            )
            return {"steps": data}
    raise ValueError(
        f"期望 json 对象 (schema={schema_cls.__name__}), 实际类型={type(data).__name__}"
    )


def _retry_hint(schema_cls: type[BaseModel], err: Exception) -> str:
    return (
        f"你上一次输出无法通过校验 ({type(err).__name__}: {err}). "
        f"请重新输出一个合法的 json 对象 (不要数组顶层, 不要 markdown), 字段需满足:\n"
        f"{_schema_hint(schema_cls)}"
    )


async def ainvoke_structured(
    *,
    llm: BaseChatModel,
    schema_cls: type[T],
    messages: list[dict[str, str]],
    model_name: str | None,
    max_attempts: int = STRUCTURED_MAX_ATTEMPTS,
) -> T:
    """调用 LLM 并返回 Pydantic 对象.

    所有模型统一走 JSON 文本解析, 避免部分 OpenAI 兼容接口不支持 SDK Pydantic parse.
    解析/校验失败时最多重试 max_attempts - 1 次, 仍失败则抛出最后一次异常.
    """
    # 注意: DashScope 兼容接口对 response_format=json_object 有一个硬约束 —
    # messages 里必须出现**小写** "json" 字样, 否则返回 400
    #   "messages must contain the word 'json' in some form".
    # OpenAI 官方校验是大小写不敏感的, DashScope 的实现更严, 这里统一用小写, 并多写几次保险.
    json_instruction = {
        "role": "system",
        "content": (
            "你必须只输出一个合法的 json 对象 (严格 json 格式, 小写 json), "
            "不要 markdown, 不要代码块, 不要解释, 顶层必须是对象 {{...}} 而不是数组 [...].\n"
            "json 字段要求:\n"
            f"{_schema_hint(schema_cls)}"
        ),
    }

    json_llm = llm.bind(response_format={"type": "json_object"})
    attempt_messages = list(messages)
    last_error: Exception | None = None
    attempts = max(1, max_attempts)

    for attempt in range(1, attempts + 1):
        try:
            resp = await json_llm.ainvoke([json_instruction, *attempt_messages])
            content = getattr(resp, "content", resp)
            if isinstance(content, list):
                text = "".join(
                    item.get("text", "") if isinstance(item, dict) else str(item)
                    for item in content
                )
            else:
                text = str(content)
            data = _extract_json(text)
            data = _coerce_parsed_data(data, schema_cls)
            obj = schema_cls.model_validate(data)
            if attempt > 1:
                logger.info(
                    f"[structured] {schema_cls.__name__} 第 {attempt}/{attempts} 次调用成功"
                )
            else:
                logger.debug(f"[structured] JSON parsed as {schema_cls.__name__}: {obj}")
            return obj
        except (ValidationError, ValueError, json.JSONDecodeError) as e:
            last_error = e
            logger.warning(
                f"[structured] {schema_cls.__name__} 第 {attempt}/{attempts} 次失败: {e}"
            )
            if attempt >= attempts:
                break
            attempt_messages = attempt_messages + [
                {"role": "user", "content": _retry_hint(schema_cls, e)},
            ]
        except Exception as e:
            # 网络/限流等: 同样计入重试次数, 避免一次失败就进 fallback
            last_error = e
            logger.warning(
                f"[structured] {schema_cls.__name__} 第 {attempt}/{attempts} 次调用异常: {e}"
            )
            if attempt >= attempts:
                break
            attempt_messages = attempt_messages + [
                {
                    "role": "user",
                    "content": (
                        f"上次请求失败 ({type(e).__name__}: {e}). "
                        "请再次只输出符合要求的 json 对象."
                    ),
                },
            ]

    assert last_error is not None
    logger.error(
        f"[structured] {schema_cls.__name__} 已达最大尝试次数 {attempts}, 交由上层兜底"
    )
    raise last_error