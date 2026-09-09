"""Durable invocation detail and explicit task spending controls."""
from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..chat_service import ChatService
from ..usage_ledger import UsageLedger
from .dependencies import get_service

Service = Annotated[ChatService, Depends(get_service)]


def invocations(service: Service, task_id: str = '', run_id: str = '', session_id: str = '', since: float = Query(default=0, ge=0)):
    ledger = UsageLedger(service.run_store)
    filters = dict(task_id=task_id, run_id=run_id, session_id=session_id, since=since)
    return {'records': ledger.records(**filters), 'summary': ledger.summary(**filters)}


def limits(task_id: str, service: Service, body: dict = Body()):
    if not task_id or len(task_id) > 240:
        raise HTTPException(422, 'Invalid task identity')
    try:
        return {'limits': UsageLedger(service.run_store).set_limits(task_id, body), 'estimated_spending_control': True}
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc


def reconcile(invocation_id: str, service: Service, body: dict = Body()):
    try:
        return UsageLedger(service.run_store).reconcile(invocation_id, body.get('family'), body.get('usage'), body.get('provider_reference'))
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc


def register_routes(router: APIRouter):
    router.add_api_route('/api/usage/invocations/{invocation_id}/reconcile', reconcile, methods=['POST'])
    router.add_api_route('/api/usage/invocations', invocations, methods=['GET'])
    router.add_api_route('/api/usage/tasks/{task_id}/limits', limits, methods=['PUT'])
