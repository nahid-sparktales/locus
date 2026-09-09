"""Headless connector adapters; cursors advance only after durable ingestion."""
from __future__ import annotations

import asyncio
import base64
import email.utils
import ipaddress
import json
import socket
import time
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import quote, urlsplit

import requests


class RuntimeConnectors:
    def __init__(self, runtime):
        self.runtime = runtime
        self.store = runtime.service.run_store

    def secret(self, key):
        value = self.runtime.private.read().get(f"connector:{key}")
        if not isinstance(value, dict):
            raise ValueError("This runtime needs the selected connector credential")
        return value

    def http(self, method, url, **kwargs):
        try:
            with requests.Session() as client:
                response = client.request(method, url, timeout=35, allow_redirects=False, stream=True, **kwargs)
                if response.status_code >= 300:
                    raise ValueError(f"Connector returned HTTP {response.status_code}")
                chunks, size = [], 0
                for chunk in response.iter_content(65536):
                    size += len(chunk)
                    if size > 32 * 1024 * 1024:
                        raise ValueError("Connector response exceeds the size limit")
                    chunks.append(chunk)
                return json.loads(b"".join(chunks))
        except requests.RequestException:
            raise ValueError("The connector could not be reached") from None

    def gmail(self, key, path, *, method="GET", body=None, params=None):
        credential = self.secret(key)
        if float(credential.get("expires_at") or 0) < time.time() + 60:
            if not credential.get("refresh_token") or not credential.get("client_id"):
                raise ValueError("Reconnect Gmail to refresh its authorization")
            refreshed = self.http("POST", "https://oauth2.googleapis.com/token", data={
                "grant_type": "refresh_token", "refresh_token": credential["refresh_token"], "client_id": credential["client_id"]})
            credential.update(access_token=refreshed["access_token"], expires_at=str(time.time() + refreshed.get("expires_in", 3600)))
            self.runtime.private.set(f"connector:{key}", credential)
        return self.http(method, f"https://gmail.googleapis.com/gmail/v1/users/me/{path}",
                         headers={"Authorization": f"Bearer {credential['access_token']}"}, json=body, params=params)

    def telegram(self, key, method, body):
        token = self.secret(key).get("bot_token")
        if not token:
            raise ValueError("This runtime needs the Telegram bot credential")
        result = self.http("POST", f"https://api.telegram.org/bot{token}/{method}", json=body)
        if not result.get("ok"):
            raise ValueError("Telegram rejected the request")
        return result

    async def poll(self, connection):
        key = connection["id"]
        try:
            events, cursor = await asyncio.to_thread(self._poll, connection)
            for event in events:
                await asyncio.to_thread(self.store.ingest_event, key, event)
            await asyncio.to_thread(self.store.update_connector_cursor, key, cursor)
            await asyncio.sleep(max(15, min(int((connection.get("public_config") or {}).get("poll_interval_seconds", 30)), 3600)))
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never persist exception URLs: Telegram embeds its token in them.
            self.store.update_connector_cursor(key, connection.get("cursor", {}), health="error",
                                               error="Connector unavailable. Check this runtime's credentials and source configuration.")
            await asyncio.sleep(30)

    @staticmethod
    def event(source, key, *, text="", subject="", actor=None, data=None, occurred=None, **fields):
        return {"source": source, "source_event_id": str(key), "event_type": "message",
                "occurred_at": occurred or time.time(), "actor": actor or {}, "subject": subject,
                "text": text, "recipients": [], "labels": [], "attachments": [], "data": data or {}, **fields}

    @staticmethod
    def gmail_text(payload):
        parts = [payload]
        texts = []
        while parts:
            part = parts.pop(0)
            parts.extend(part.get("parts", []))
            value = part.get("body", {}).get("data")
            if value and part.get("mimeType", "").startswith("text/"):
                texts.append(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode("utf-8", "replace"))
        return "\n".join(texts)

    def _poll(self, connection):
        key, kind = connection["id"], connection["kind"]
        cursor = dict(connection.get("cursor") or {})
        if kind == "webhook":
            return [], cursor
        if kind == "telegram":
            result = self.telegram(key, "getUpdates", {"offset": int(cursor.get("offset", 0)), "timeout": 20, "limit": 100})
            events = []
            for update in result.get("result", []):
                cursor["offset"] = max(cursor.get("offset", 0), update["update_id"] + 1)
                message = next((update[name] for name in ("message", "edited_message", "channel_post", "edited_channel_post") if name in update), None)
                if not message:
                    continue
                actor, chat = message.get("from", message.get("sender_chat", {})), message.get("chat", {})
                events.append(self.event(kind, update["update_id"], text=message.get("text", message.get("caption", "")),
                                         subject=chat.get("title", "Telegram message"), occurred=message.get("date"),
                                         actor={"id": str(actor.get("id", "")), "username": actor.get("username", "")},
                                         data={"chat_id": str(chat.get("id", "")), "message_id": message.get("message_id")}))
            return events, cursor
        if kind == "gmail":
            if not cursor.get("history_id"):
                return [], {"history_id": self.gmail(key, "profile")["historyId"], "last_successful_at": time.time()}
            ids, page = [], ""
            while True:
                params = {"startHistoryId": cursor["history_id"], "historyTypes": "messageAdded", "maxResults": 100}
                if page:
                    params["pageToken"] = page
                result = self.gmail(key, "history", params=params)
                for item in result.get("history", []):
                    ids.extend(value["message"]["id"] for value in item.get("messagesAdded", []))
                new_history = result.get("historyId", cursor["history_id"])
                page = result.get("nextPageToken", "")
                if not page:
                    break
            events = []
            for message_id in dict.fromkeys(ids):
                item = self.gmail(key, "messages/" + quote(message_id, safe=""), params={"format": "full"})
                payload = item.get("payload", {})
                headers = {field["name"].lower(): field["value"] for field in payload.get("headers", [])}
                events.append(self.event(kind, message_id, text=self.gmail_text(payload) or item.get("snippet", ""),
                                         subject=headers.get("subject", ""), occurred=int(item.get("internalDate", 0))/1000,
                                         actor={"email": email.utils.parseaddr(headers.get("from", ""))[1]},
                                         recipients=[address for _, address in email.utils.getaddresses([headers.get("to", ""), headers.get("cc", "")])],
                                         labels=item.get("labelIds", []), data={"thread_id": item.get("threadId", ""), "message_id": message_id}))
            return events, {**cursor, "history_id": new_history, "last_successful_at": time.time()}
        if kind == "price_feed":
            return self.prices(connection), cursor
        raise ValueError("Unsupported connector")

    def prices(self, connection):
        config = connection.get("public_config") or {}
        credentials = self.runtime.private.read().get(f"connector:{connection['id']}") or {}
        conditions = [trigger.get("filters", {}).get("price_condition") for trigger in self.store.event_triggers()
                      if trigger.get("connection_id") == connection["id"] and trigger.get("enabled")]
        events = []
        for condition in conditions:
            if not condition:
                continue
            symbol = condition.get("provider_symbol") or condition.get("symbol", "")
            endpoint = str(config.get("endpoint_template", "")).replace("{symbol}", quote(symbol, safe=""))
            parsed = urlsplit(endpoint)
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError("Price sources require HTTPS")
            if not config.get("allow_local_network"):
                for address in socket.getaddrinfo(parsed.hostname, parsed.port or 443):
                    if not ipaddress.ip_address(address[4][0]).is_global:
                        raise ValueError("Price source requires local-network permission")
            headers, params = {}, {}
            for field in config.get("secret_fields", []):
                name = field["key"]
                (headers if field.get("placement") == "header" else params)[name] = credentials[name]
            result = self.http("GET", endpoint, headers=headers, params=params)
            value = result
            for part in str(config.get("price_path", config.get("price_json_path", "price"))).removeprefix("$.").split("."):
                value = value[int(part)] if isinstance(value, list) else value[part]
            quoted_at = time.time()
            timestamp_path = config.get("timestamp_json_path", "")
            if timestamp_path:
                stamp = result
                for part in timestamp_path.removeprefix("$.").split("."):
                    stamp = stamp[int(part)] if isinstance(stamp, list) else stamp[part]
                try:
                    quoted_at = float(stamp)
                    if quoted_at > 1e12:
                        quoted_at /= 1000
                except (TypeError, ValueError):
                    from datetime import datetime
                    quoted_at = datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
            if time.time() - quoted_at > int(config.get("max_quote_age_seconds", 300)):
                continue
            events.append(self.event("price_feed", f"{symbol}:{quoted_at}", event_type="price.quote", subject=symbol,
                                     data={"symbol": condition.get("symbol", symbol), "provider_symbol": symbol,
                                           "price": str(value), "quote_currency": condition.get("quote_currency", "USD"),
                                           "asset_class": condition.get("asset_class", "crypto"), "provider_timestamp": quoted_at}))
        return events

    async def action(self, event):
        try:
            return await asyncio.to_thread(self._action, event)
        except Exception:
            return {"error": "Connector action failed or its outcome is uncertain. Inspect the source before retrying."}

    def _action(self, event):
        args, tool = event.get("arguments", {}), event["tool"]
        key = args.get("connection_id", "")
        connection = self.store.connector_connection(key)
        if not connection or not connection["enabled"]:
            raise ValueError("Connector unavailable")
        if tool == "gmail_fetch_thread":
            result = self.gmail(key, "threads/" + quote(args["thread_id"], safe=""), params={"format": "full"})
        elif tool == "gmail_change_labels":
            collection = "threads" if args.get("target_type") == "thread" else "messages"
            result = self.gmail(key, f"{collection}/{quote(args['target_id'], safe='')}/modify", method="POST",
                                body={"addLabelIds": args.get("add_label_ids", []), "removeLabelIds": args.get("remove_label_ids", [])})
        elif tool in {"gmail_create_draft", "gmail_send"}:
            message = EmailMessage()
            for header in ("to", "cc", "bcc", "subject"):
                if args.get(header):
                    message[header] = ", ".join(args[header]) if isinstance(args[header], list) else args[header]
            message.set_content(args.get("body", args.get("text", "")))
            body = {"raw": base64.urlsafe_b64encode(message.as_bytes()).decode()}
            if args.get("thread_id"):
                body["threadId"] = args["thread_id"]
            result = self.gmail(key, "messages/send" if tool == "gmail_send" else "drafts", method="POST",
                                body=body if tool == "gmail_send" else {"message": body})
        elif tool == "telegram_send":
            body = {"chat_id": args["chat_id"], "text": args["text"]}
            if args.get("reply_to_message_id"):
                body["reply_parameters"] = {"message_id": args["reply_to_message_id"]}
            result = self.telegram(key, "sendMessage", body)
        elif tool == "telegram_fetch_file":
            token = self.secret(key)["bot_token"]
            file = self.telegram(key, "getFile", {"file_id": args["file_id"]})["result"]
            if int(file.get("file_size", 0)) > 25 * 1024 * 1024:
                raise ValueError("Attachment exceeds the size limit")
            remote_path = str(file["file_path"])
            if ".." in Path(remote_path).parts or remote_path.startswith("/"):
                raise ValueError("Invalid Telegram file path")
            with requests.get(f"https://api.telegram.org/file/bot{token}/{quote(remote_path, safe='/')}", timeout=35, stream=True, allow_redirects=False) as response:
                if response.status_code != 200:
                    raise ValueError("The attachment could not be downloaded")
                content = bytearray()
                for chunk in response.iter_content(65536):
                    content.extend(chunk)
                    if len(content) > 25 * 1024 * 1024:
                        raise ValueError("Attachment exceeds the size limit")
            result = self.save_attachment(event, args, bytes(content))
        elif tool == "gmail_fetch_attachment":
            result = self.gmail(key, f"messages/{quote(args['message_id'], safe='')}/attachments/{quote(args['attachment_id'], safe='')}")
            encoded = result["data"]
            data = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
            result = self.save_attachment(event, args, data)
        else:
            raise ValueError("Unsupported connector action")
        return {"text": json.dumps(result, ensure_ascii=False)}

    def save_attachment(self, event, args, data):
        worker = self.runtime.store.worker(event["session_id"])
        root = Path(worker["workspace"])
        filename = Path(args.get("filename") or args.get("file_id", "attachment")).name
        target = (root / "Downloads" / filename).resolve()
        if root not in target.parents or len(data) > 25 * 1024 * 1024:
            raise ValueError("Attachment outside the allowed workspace or too large")
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        return {"path": str(target)}
