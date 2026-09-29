"""Bundled Google Calendar / Drive MCP adapter. Credentials arrive only in memory.

Runs with Locus's Python interpreter over STDIO, without a third-party package
installer. No endpoint supplied by a model is ever used for authenticated calls.
"""
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any
from urllib.parse import quote

import requests

MAX_RESPONSE = 2 * 1024 * 1024


class GoogleWorkspace:
    def __init__(self, credentials: dict[str, str], session: Any = None):
        self.credentials = dict(credentials)
        self.http = session or requests.Session()

    def token(self) -> str:
        if self.credentials.get("access_token") and float(self.credentials.get("expires_at") or 0) > time.time() + 60:
            return self.credentials["access_token"]
        if not self.credentials.get("refresh_token") or not self.credentials.get("client_id"):
            raise ValueError("Connect your Google account in Locus Plugins first.")
        response = self.http.post("https://oauth2.googleapis.com/token", data={
            "client_id": self.credentials["client_id"], "refresh_token": self.credentials["refresh_token"],
            "grant_type": "refresh_token",
        }, timeout=30, allow_redirects=False)
        if response.status_code != 200:
            raise ValueError("Google sign-in expired. Reconnect this account in Locus Plugins.")
        value = response.json()
        self.credentials.update(access_token=value["access_token"],
                                expires_at=str(time.time() + int(value.get("expires_in", 3600))))
        return self.credentials["access_token"]

    def request(self, method: str, path: str, *, params=None, body=None, text=False):
        if not path.startswith(("calendar/v3/", "drive/v3/")):
            raise ValueError("Unsupported Google API")
        if params:
            params = {key: value for key, value in params.items() if value != ""}
        # Never retry writes automatically; a network failure can follow a successful write.
        with self.http.request(method, "https://www.googleapis.com/" + path,
                headers={"Authorization": "Bearer " + self.token()}, params=params,
                json=body, timeout=30, allow_redirects=False, stream=True) as response:
            if not 200 <= response.status_code < 300:
                raise ValueError(f"Google returned HTTP {response.status_code}. Check account permissions; reconnect for an expired sign-in.")
            data = bytearray()
            for chunk in response.iter_content(65536):
                data.extend(chunk)
                if len(data) > MAX_RESPONSE:
                    raise ValueError("Google result is too large. Narrow the query or open the file in Drive.")
            return data.decode("utf-8") if text else json.loads(data or b"{}")


def segment(value: str) -> str:
    if not value or len(value) > 1024 or value in {".", ".."}:
        raise ValueError("Invalid Google resource ID")
    return quote(value, safe="")


def create_server(kind: str, google: GoogleWorkspace):
    from mcp.server import MCPServer
    from mcp.types import ToolAnnotations
    server = MCPServer("Locus Google " + kind.title())
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True)
    write = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=True)
    change = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=True)
    if kind == "calendar":
        @server.tool(annotations=read)
        def list_calendars(page_token: str = "") -> dict:
            """List connected calendars. Pass nextPageToken to fetch the next page."""
            return google.request("GET", "calendar/v3/users/me/calendarList", params={"maxResults": 100, "pageToken": page_token})

        @server.tool(annotations=read)
        def list_events(time_min: str, time_max: str, calendar_id: str = "primary", query: str = "", page_token: str = "") -> dict:
            """Read events within RFC3339 timestamps with time zones. Supports pagination."""
            return google.request("GET", f"calendar/v3/calendars/{segment(calendar_id)}/events", params={
                "timeMin": time_min, "timeMax": time_max, "q": query, "pageToken": page_token,
                "singleEvents": "true", "orderBy": "startTime", "maxResults": 100})

        @server.tool(annotations=read)
        def get_event(event_id: str, calendar_id: str = "primary") -> dict:
            """Read one event before changing it."""
            return google.request("GET", f"calendar/v3/calendars/{segment(calendar_id)}/events/{segment(event_id)}")

        @server.tool(annotations=write)
        def create_event(summary: str, start: dict, end: dict, calendar_id: str = "primary", description: str = "", location: str = "") -> dict:
            """Create an event after approval. Start/end use dateTime + timeZone, or date for all-day events. Does not invite attendees."""
            return google.request("POST", f"calendar/v3/calendars/{segment(calendar_id)}/events", body={
                "summary": summary, "start": start, "end": end, "description": description, "location": location})

        @server.tool(annotations=change)
        def update_event(event_id: str, changes: dict, calendar_id: str = "primary") -> dict:
            """Update an event after approval. Allowed fields: summary, description, location, start, end."""
            if not changes or set(changes) - {"summary", "description", "location", "start", "end"}:
                raise ValueError("Only summary, description, location, start and end may be changed")
            return google.request("PATCH", f"calendar/v3/calendars/{segment(calendar_id)}/events/{segment(event_id)}", body=changes)

        @server.tool(annotations=change)
        def delete_event(event_id: str, calendar_id: str = "primary") -> dict:
            """Delete an event only after the user approves the exact event."""
            google.request("DELETE", f"calendar/v3/calendars/{segment(calendar_id)}/events/{segment(event_id)}")
            return {"deleted": True, "event_id": event_id}
    elif kind == "drive":
        @server.tool(annotations=read)
        def search_files(query: str = "", page_token: str = "") -> dict:
            """Search file names in Google Drive. Returns nextPageToken when more files are available."""
            escaped = query.replace("\\", "\\\\").replace("'", "\\'")
            return google.request("GET", "drive/v3/files", params={
                "q": "trashed = false" + (f" and name contains '{escaped}'" if query else ""),
                "pageToken": page_token, "pageSize": 100, "supportsAllDrives": "true", "includeItemsFromAllDrives": "true",
                "fields": "nextPageToken,files(id,name,mimeType,modifiedTime,webViewLink,description)",})

        @server.tool(annotations=read)
        def read_file(file_id: str) -> dict:
            """Read Google Docs as text, Sheets as CSV, or small text files. Other types return a Drive link."""
            path = "drive/v3/files/" + segment(file_id)
            metadata = google.request("GET", path, params={"fields": "id,name,mimeType,webViewLink", "supportsAllDrives": "true"})
            mime = metadata.get("mimeType", "")
            exports = {"application/vnd.google-apps.document": "text/plain", "application/vnd.google-apps.spreadsheet": "text/csv",
                       "application/vnd.google-apps.presentation": "text/plain"}
            if mime in exports:
                metadata["text"] = google.request("GET", path + "/export", params={"mimeType": exports[mime]}, text=True)
            elif mime.startswith("text/") or mime in {"application/json", "application/xml"}:
                metadata["text"] = google.request("GET", path, params={"alt": "media", "supportsAllDrives": "true"}, text=True)
            return metadata
    else:
        raise ValueError("Unknown Google Workspace service")
    return server


if __name__ == "__main__":
    credentials = json.loads(os.environ.pop("LOCUS_GOOGLE_CREDENTIALS", "{}"))
    create_server(sys.argv[1], GoogleWorkspace(credentials)).run("stdio")
