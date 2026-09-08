"""Read-only DAG/policy validation. It never launches workers or grants authority."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath

ACTIVE = {"launching", "running"}
STATES = {"planned", "launching", "running", "blocked", "complete", "cancelled"}
EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}


def _strings(value):
    return isinstance(value, list) and all(isinstance(x, str) and x.strip() for x in value)


def _reference(value):
    return isinstance(value, str) and bool(value.strip())


def _path_valid(value):
    return (
        value != "."
        and not PurePosixPath(value).is_absolute()
        and ".." not in value.split("/")
        and "\\" not in value
        and not any(c in value for c in "*?[]")
        and str(PurePosixPath(value)) == value.rstrip("/")
    )


def _conflict(a, b):
    if set(a.get("exclusive_resources", [])) & set(b.get("exclusive_resources", [])):
        return True
    for left in a.get("write_paths", []):
        for right in b.get("write_paths", []):
            left, right = left.rstrip("/"), right.rstrip("/")
            if left == right or left.startswith(right + "/") or right.startswith(left + "/"):
                return True
    return False


def inspect_manifest(data):
    errors = []
    result = {
        "ok": False,
        "errors": errors,
        "ready_candidates": [],
        "dispatchable": [],
        "deferred_conflicts": [],
        "authority_note": "Declared policy only; the supervisor must verify user authority, evidence and runtime settings.",
    }
    if not isinstance(data, dict):
        errors.append("manifest must be an object")
        return result
    mode = data.get("mode")
    limit = data.get("max_parallelism")
    result["mode"] = mode
    result["execution_authorized"] = data.get("execution_authorized")
    if data.get("schema_version") != "codex-loop-execution.v1":
        errors.append("unsupported schema_version")
    if not isinstance(mode, str) or mode not in {"plan", "review", "execute"}:
        errors.append("mode must be plan, review or execute")
    if type(data.get("execution_authorized")) is not bool:
        errors.append("execution_authorized must be explicit boolean")
    if type(limit) is not int or limit < 1:
        errors.append("max_parallelism must be a positive integer")
    if type(data.get("fast_authorized")) is not bool:
        errors.append("fast_authorized must be explicit boolean")
    fast_authorized = data.get("fast_authorized") is True and _reference(data.get("fast_authority_ref"))
    raw_nodes = data.get("nodes")
    if not isinstance(raw_nodes, list) or not raw_nodes:
        errors.append("nodes must be a nonempty list")
        return result
    nodes = {}
    for item in raw_nodes:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"].strip():
            errors.append("every node requires a nonempty id")
            continue
        key = item["id"]
        if key in nodes:
            errors.append(f"duplicate node: {key}")
            continue
        nodes[key] = item
        state = item.get("status")
        if not isinstance(state, str) or state not in STATES:
            errors.append(f"{key}: invalid status")
            continue
        for field in ("depends_on", "write_paths", "exclusive_resources"):
            value = item.get(field)
            if not _strings(value):
                errors.append(f"{key}: {field} must be a string list")
            elif len(value) != len(set(value)):
                errors.append(f"{key}: duplicate {field} entry")
        if _strings(item.get("write_paths")):
            if not all(_path_valid(p) for p in item["write_paths"]):
                errors.append(f"{key}: write_paths must be canonical repo-relative paths, without globs or escapes")
        if item.get("status") == "complete":
            if item.get("acceptance") != "passed" or not _strings(item.get("evidence")) or not item.get("evidence"):
                errors.append(f"{key}: complete requires passed acceptance and evidence references")
        if item.get("status") in ACTIVE and not _reference(item.get("runtime_ref")):
            errors.append(f"{key}: active node requires runtime_ref or launch reservation")
        if item.get("status") == "planned" and item.get("runtime_ref"):
            errors.append(f"{key}: launch already reserved; reconcile status before dispatch")
        policy = item.get("session")
        if not isinstance(policy, dict):
            errors.append(f"{key}: explicit session policy required")
            continue
        if not isinstance(policy.get("model"), str) or not policy["model"].strip():
            errors.append(f"{key}: model required")
        effort = policy.get("reasoning_effort")
        tier = policy.get("service_tier")
        if not isinstance(effort, str) or effort not in EFFORTS:
            errors.append(f"{key}: unsupported reasoning_effort name")
        if not isinstance(tier, str) or tier not in {"default", "priority"}:
            errors.append(f"{key}: service_tier must be default or explicitly authorized priority")
        if type(policy.get("fast_mode")) is not bool:
            errors.append(f"{key}: fast_mode must be explicit boolean")
        elif (policy.get("service_tier") == "priority") != policy["fast_mode"]:
            errors.append(f"{key}: contradictory speed tier and Fast flag")
        if (policy.get("service_tier") == "priority" or policy.get("fast_mode") is True) and not fast_authorized:
            errors.append(f"{key}: Fast requires explicit user authority reference")
        if isinstance(effort, str) and effort in {"ultra", "max"} and item.get("role", "worker") != "supervisor":
            if not _reference(item.get("high_effort_authority_ref")):
                errors.append(f"{key}: highest worker effort requires explicit user override")
    if errors:
        return result
    for key, item in nodes.items():
        for dep in item["depends_on"]:
            if dep not in nodes:
                errors.append(f"{key}: missing dependency {dep}")
    if errors:
        return result
    colors = {}

    def visit(key):
        if colors.get(key) == 1:
            errors.append(f"dependency cycle at {key}")
            return
        if colors.get(key) == 2:
            return
        colors[key] = 1
        for dep in nodes[key]["depends_on"]:
            visit(dep)
        colors[key] = 2

    for key in nodes:
        visit(key)
    if errors:
        return result
    active = [n for n in nodes.values() if n["status"] in ACTIVE]
    for index, item in enumerate(active):
        for other in active[index + 1:]:
            if item["runtime_ref"] == other["runtime_ref"] or _conflict(item, other):
                errors.append(f"active ownership/resource conflict: {item['id']} / {other['id']}")
        if not all(nodes[d]["status"] == "complete" for d in item["depends_on"]):
            errors.append(f"{item['id']}: active before predecessors completed")
    if len(active) > limit:
        errors.append("active workers exceed max_parallelism")
    if active and (mode != "execute" or not data["execution_authorized"]):
        errors.append("active workers exist outside authorized execution mode")
    if errors:
        return result
    ready = [n for n in nodes.values() if n["status"] == "planned" and all(nodes[d]["status"] == "complete" for d in n["depends_on"])]
    result["ready_candidates"] = [n["id"] for n in ready]
    result["ok"] = True
    if mode != "execute" or not data["execution_authorized"]:
        return result
    selected = []
    for item in ready:
        conflicts = [n["id"] for n in active + selected if _conflict(item, n)]
        if conflicts:
            result["deferred_conflicts"].append({"id": item["id"], "conflicts_with": conflicts})
        elif len(active) + len(selected) < limit:
            selected.append(item)
    result["dispatchable"] = [n["id"] for n in selected]
    return result


def inspect_file(path: Path):
    try:
        return inspect_manifest(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return {"ok": False, "errors": [f"cannot read execution manifest: {type(exc).__name__}"], "ready_candidates": [], "dispatchable": []}
