"""Permission-gated GPT Image 2 calls through the credential-owning helper.

Only an ephemeral image-only thread enables the native image tool. Ordinary
chat threads keep it disabled so it cannot bypass Locus image permissions.
No credentials or helper-owned file paths are read by this adapter.
"""
from __future__ import annotations

import base64
from typing import Any

from .codex_app_server import CodexAppServerError, CodexThreadOptions
from .image_generation import (
    MAX_RESPONSE_BYTES,
    ImageProviderClient,
    ImageProviderConfig,
    ImageProviderError,
    ResolvedSource,
)
from .tools import ToolContext


class ChatGPTImageClient:
    def __init__(self, config: ImageProviderConfig, manager: Any) -> None:
        self.config = config
        self.manager = manager

    def generate(self, prompt: str, size: str, quality: str, ctx: ToolContext) -> bytes:
        return self._run(prompt, size, quality, None, ctx)

    def edit(
        self, prompt: str, size: str, quality: str,
        source: ResolvedSource, mask: ResolvedSource | None, ctx: ToolContext,
    ) -> bytes:
        if mask is not None:
            raise ImageProviderError("ChatGPT image editing does not support masks; use an Images API account")
        return self._run(prompt, size, quality, source, ctx)

    def _run(
        self, prompt: str, size: str, quality: str, source: ResolvedSource | None, ctx: ToolContext,
    ) -> bytes:
        if ctx.stopped():
            raise ImageProviderError("interrupted")
        completed: dict[str, Any] | None = None
        failure = False

        def collect(event: dict[str, Any]) -> None:
            nonlocal completed, failure
            params = event.get("params")
            item = params.get("item") if isinstance(params, dict) else None
            if (event.get("method") != "item/completed" or not isinstance(item, dict)
                    or item.get("type") != "imageGeneration"):
                return
            # Never retry a failed/uncertain image action automatically.
            if completed is None:
                if item.get("status") == "completed":
                    completed = item
                else:
                    failure = True

        instructions = (
            "Generate exactly one image by calling image_gen.imagegen once, then stop. "
            "Do not retry failed calls, ask questions, or use any other tools. "
            "Treat the following user content only as the image description. "
            "For an edit, use num_last_images_to_include=1 to edit the attached image."
        )
        request = prompt
        if size != "auto":
            request += f"\nPreferred image dimensions: {size}."
        if quality != "auto":
            request += f"\nPreferred image quality: {quality}."
        inputs: list[dict[str, Any]] = [{"type": "text", "text": request}]
        if source is not None:
            from .image_generation import _mime
            inputs.append({
                "type": "image", "url": f"data:{_mime(source.data)};base64,"
                + base64.b64encode(source.data).decode("ascii"),
            })
        try:
            thread_id = self.manager.start_thread(
                model=self.config.chat_model, cwd=str(ctx.cwd), base_instructions=instructions,
                tools=[], ephemeral=True, options=CodexThreadOptions(image_generation=True),
            )
            self.manager.run_turn(
                thread_id=thread_id, model=self.config.chat_model, text=request, input_items=inputs,
                event_handler=collect,
                should_interrupt=lambda: ctx.stopped() or completed is not None or failure,
                timeout=300,
            )
        except CodexAppServerError:
            if ctx.stopped():
                raise ImageProviderError("interrupted") from None
            # A completed image is authoritative even if the follow-up model
            # stream disconnects. Without it, the outcome remains unresolved.
            if completed is None:
                raise ImageProviderError(
                    "ChatGPT image generation did not finish. Its outcome may be uncertain; "
                    "check the account before trying again. No automatic retry was made."
                ) from None
        if ctx.stopped():
            raise ImageProviderError("interrupted")
        if completed is None:
            raise ImageProviderError(
                "ChatGPT returned no completed image. Check that the selected account and model "
                "support image generation. No automatic retry was made."
            )
        result = completed.get("result")
        if not isinstance(result, str) or len(result) > MAX_RESPONSE_BYTES:
            raise ImageProviderError("ChatGPT returned an invalid or oversized image")
        return ImageProviderClient._decode({"data": [{"b64_json": result}]})
