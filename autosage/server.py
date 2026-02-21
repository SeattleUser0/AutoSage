from __future__ import annotations

from typing import Any, Dict

from autosage.tools import ngspice


REGISTRY = {
    "ngspice": {
        "ops": {
            "version": {"inputs_schema": {"type": "object", "properties": {}}},
            "smoketest": {"inputs_schema": {"type": "object", "properties": {}}},
            "validate_netlist": {
                "inputs_schema": {
                    "type": "object",
                    "required": ["netlist_text"],
                    "properties": {"netlist_text": {"type": "string"}},
                }
            },
        }
    }
}


def error_response(error_type: str, message: str, details: dict | None = None) -> dict:
    return {
        "ok": False,
        "stdout": "",
        "stderr": "",
        "files": [],
        "metrics": {"elapsed_ms": 0, "exit_code": -1},
        "error": {"type": error_type, "message": message, "details": details or {}},
    }


def handle_run(payload: Dict[str, Any]) -> dict:
    if not isinstance(payload, dict):
        return error_response("invalid_request", "Request body must be a JSON object.")

    tool = payload.get("tool")
    op = payload.get("op")
    inputs = payload.get("inputs") or {}
    limits = payload.get("limits") or {}

    if tool != "ngspice":
        return error_response("unknown_tool", "Unsupported tool.", {"tool": tool})
    if op not in {"version", "smoketest", "validate_netlist"}:
        return error_response("unknown_op", "Unsupported operation.", {"op": op})
    if not isinstance(inputs, dict):
        return error_response("invalid_request", "inputs must be an object.")
    if not isinstance(limits, dict):
        return error_response("invalid_request", "limits must be an object.")

    if op == "version":
        return ngspice.version(limits=limits)
    if op == "smoketest":
        return ngspice.smoketest(limits=limits)

    netlist_text = inputs.get("netlist_text")
    return ngspice.validate_netlist(netlist_text=netlist_text, limits=limits)


def create_fastapi_app():
    from fastapi import FastAPI

    app = FastAPI(title="AutoSage", version="0.1.0")

    @app.get("/tools")
    def get_tools():
        return REGISTRY

    @app.post("/run")
    def post_run(payload: Dict[str, Any]):
        return handle_run(payload)

    return app


def create_flask_app():
    from flask import Flask, jsonify, request

    app = Flask(__name__)

    @app.get("/tools")
    def get_tools():
        return jsonify(REGISTRY)

    @app.post("/run")
    def post_run():
        payload = request.get_json(silent=True)
        return jsonify(handle_run(payload))

    return app


def create_app():
    try:
        return create_fastapi_app()
    except Exception:
        pass
    try:
        return create_flask_app()
    except Exception:
        raise RuntimeError("Neither FastAPI nor Flask is installed.")


try:
    app = create_app()
except RuntimeError:
    app = None
