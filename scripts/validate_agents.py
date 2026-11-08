from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = ROOT / ".agents" / "skills"
OMP_ROOT = ROOT / ".omp"
AGENT_ROOT = OMP_ROOT / "agents"
CONFIG_PATH = OMP_ROOT / "config.yml"
MCP_PATH = OMP_ROOT / "mcp.json"
LOCK_PATH = ROOT / "SKILLS_LOCK.yaml"

EXPECTED_AGENTS = {
    "eiu-db-executor",
    "eiu-ui-executor",
    "eiu-debugger",
    "eiu-general-executor",
    "eiu-reviewer",
}

CORE_GOVERNANCE_PATHS = [
    ROOT / "AGENTS.md",
    ROOT / "REVIEW.md",
    ROOT / "SKILLS.md",
    ROOT / "SKILLS_LOCK.yaml",
    OMP_ROOT / "RULES.md",
]

LEGACY_RUNTIME_MARKERS = (
    "AVAILABLE != LOADED != APPLIED",
    "SKILLS_RESOLVED",
    "SKILLS_APPLIED",
    "effective_provider: \"native-user",
)


def load_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path.relative_to(ROOT)} must contain a YAML mapping")
    return data


def parse_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise ValueError(f"{path.relative_to(ROOT)} is missing YAML frontmatter")

    end = text.find("\n---", 4)
    if end < 0:
        raise ValueError(f"{path.relative_to(ROOT)} has unterminated YAML frontmatter")

    frontmatter_text = text[4:end]
    data = yaml.safe_load(frontmatter_text) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path.relative_to(ROOT)} frontmatter must be a mapping")
    return data, text[end + 4 :]


def require_mapping(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{label} must be a mapping")
        return {}
    return value


def collect_project_skills(errors: list[str]) -> dict[str, Path]:
    skills: dict[str, Path] = {}

    if not SKILL_ROOT.is_dir():
        errors.append("missing .agents/skills directory")
        return skills

    for child in sorted(SKILL_ROOT.iterdir()):
        if not child.is_dir():
            continue

        skill_path = child / "SKILL.md"
        if not skill_path.is_file():
            errors.append(
                f"{child.relative_to(ROOT)}: project skill directory is missing SKILL.md"
            )
            continue

        try:
            frontmatter, _ = parse_frontmatter(skill_path)
        except Exception as exc:
            errors.append(str(exc))
            continue

        name = frontmatter.get("name")
        description = frontmatter.get("description")

        if not isinstance(name, str) or not name.strip():
            errors.append(f"{skill_path.relative_to(ROOT)}: missing non-empty name")
            continue

        if not isinstance(description, str) or not description.strip():
            errors.append(f"{skill_path.relative_to(ROOT)}: missing non-empty description")

        if name in skills:
            errors.append(
                "duplicate project skill name "
                f"{name!r}: {skills[name].relative_to(ROOT)} and {skill_path.relative_to(ROOT)}"
            )
            continue

        skills[name] = skill_path

    return skills


def validate_config(errors: list[str]) -> None:
    if not CONFIG_PATH.is_file():
        errors.append("missing .omp/config.yml")
        return

    try:
        config = load_yaml(CONFIG_PATH)
    except Exception as exc:
        errors.append(str(exc))
        return

    todo = require_mapping(config.get("todo"), ".omp/config.yml todo", errors)
    skills = require_mapping(config.get("skills"), ".omp/config.yml skills", errors)

    if todo.get("enabled") is not True:
        errors.append(".omp/config.yml requires todo.enabled=true")
    if todo.get("eager") != "always":
        errors.append(".omp/config.yml requires todo.eager=always")
    if todo.get("reminders") is not True:
        errors.append(".omp/config.yml requires todo.reminders=true")

    if skills.get("enabled") is not True:
        errors.append(".omp/config.yml requires skills.enabled=true")
    if skills.get("enableAgentsProject") is not True:
        errors.append(".omp/config.yml requires skills.enableAgentsProject=true")
    if skills.get("enableSkillCommands") is not True:
        errors.append(".omp/config.yml requires skills.enableSkillCommands=true")


def validate_agents(project_skills: dict[str, Path], errors: list[str]) -> None:
    if not AGENT_ROOT.is_dir():
        errors.append("missing .omp/agents directory")
        return

    discovered_agents: set[str] = set()

    for path in sorted(AGENT_ROOT.glob("*.md")):
        try:
            frontmatter, body = parse_frontmatter(path)
        except Exception as exc:
            errors.append(str(exc))
            continue

        name = frontmatter.get("name")
        description = frontmatter.get("description")

        if not isinstance(name, str) or not name.strip():
            errors.append(f"{path.relative_to(ROOT)}: missing non-empty agent name")
            continue
        if name in discovered_agents:
            errors.append(f"duplicate OMP project agent name {name!r}")
        discovered_agents.add(name)

        if not isinstance(description, str) or not description.strip():
            errors.append(f"{path.relative_to(ROOT)}: missing non-empty description")

        tools = frontmatter.get("tools")
        if isinstance(tools, str):
            tool_names = {part.strip() for part in tools.split(",") if part.strip()}
        elif isinstance(tools, list):
            tool_names = {str(item).strip() for item in tools if str(item).strip()}
        else:
            tool_names = set()

        if "todo" in tool_names:
            errors.append(
                f"{path.relative_to(ROOT)}: subagents must not explicitly own the parent todo tool"
            )

        autoload = frontmatter.get("autoloadSkills", [])
        if autoload is None:
            autoload = []
        if isinstance(autoload, str):
            autoload = [part.strip() for part in autoload.split(",") if part.strip()]
        if not isinstance(autoload, list):
            errors.append(f"{path.relative_to(ROOT)}: autoloadSkills must be a list or CSV string")
            autoload = []

        for raw_name in autoload:
            skill_name = str(raw_name).strip()
            if not skill_name:
                continue
            if skill_name not in project_skills:
                errors.append(
                    f"{path.relative_to(ROOT)}: autoloadSkills references non-project skill {skill_name!r}"
                )

        if "manage the parent Todo" not in body and "parent Todo" not in body:
            errors.append(
                f"{path.relative_to(ROOT)}: agent body should explicitly preserve parent Todo ownership"
            )

    missing = EXPECTED_AGENTS - discovered_agents
    if missing:
        errors.append("missing expected OMP project agents: " + ", ".join(sorted(missing)))


def iter_registry_entries(lock: dict[str, Any]) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    for key in ("project_skills", "release_skills"):
        value = lock.get(key, [])
        if isinstance(value, list):
            entries.extend(item for item in value if isinstance(item, dict))

    gitnexus = lock.get("gitnexus_skills", {})
    if isinstance(gitnexus, dict):
        items = gitnexus.get("items", [])
        if isinstance(items, list):
            entries.extend(item for item in items if isinstance(item, dict))

    return entries


def validate_registry(project_skills: dict[str, Path], errors: list[str]) -> None:
    if not LOCK_PATH.is_file():
        errors.append("missing SKILLS_LOCK.yaml")
        return

    try:
        lock = load_yaml(LOCK_PATH)
    except Exception as exc:
        errors.append(str(exc))
        return

    if lock.get("runtime_authority") != "OMP_NATIVE_DISCOVERY":
        errors.append("SKILLS_LOCK.yaml must declare runtime_authority=OMP_NATIVE_DISCOVERY")
    if lock.get("runtime_path_resolution") != "FORBIDDEN_FROM_THIS_FILE":
        errors.append("SKILLS_LOCK.yaml must forbid runtime path resolution")
    if lock.get("machine_specific_paths_allowed") is not False:
        errors.append("SKILLS_LOCK.yaml must set machine_specific_paths_allowed=false")

    registry_names: set[str] = set()
    for entry in iter_registry_entries(lock):
        name = entry.get("name")
        installed_path = entry.get("installed_path")

        if not isinstance(name, str) or not name.strip():
            errors.append("SKILLS_LOCK.yaml contains an entry without a valid name")
            continue
        registry_names.add(name)

        if not isinstance(installed_path, str) or not installed_path.strip():
            errors.append(f"SKILLS_LOCK.yaml {name}: missing installed_path")
            continue

        path = ROOT / installed_path
        if not path.is_file():
            errors.append(f"SKILLS_LOCK.yaml {name}: installed_path does not exist: {installed_path}")
            continue

        try:
            frontmatter, _ = parse_frontmatter(path)
        except Exception as exc:
            errors.append(str(exc))
            continue

        if frontmatter.get("name") != name:
            errors.append(
                f"SKILLS_LOCK.yaml {name}: installed SKILL.md declares name={frontmatter.get('name')!r}"
            )

    missing_registry = set(project_skills) - registry_names
    if missing_registry:
        errors.append(
            "project skills missing from SKILLS_LOCK.yaml provenance registry: "
            + ", ".join(sorted(missing_registry))
        )


def validate_mcp(errors: list[str]) -> None:
    if not MCP_PATH.is_file():
        errors.append("missing .omp/mcp.json")
        return

    try:
        data = json.loads(MCP_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f".omp/mcp.json parse error: {exc}")
        return

    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        errors.append(".omp/mcp.json mcpServers must be a mapping")
        return

    if "code-review-graph" in servers:
        errors.append(".omp/mcp.json must not reintroduce code-review-graph in the OMP-native baseline")

    supabase = servers.get("supabase-dev")
    if not isinstance(supabase, dict):
        errors.append(".omp/mcp.json requires supabase-dev")
    else:
        url = supabase.get("url")
        if not isinstance(url, str):
            errors.append("supabase-dev MCP requires a URL")
        else:
            if "${SUPABASE_PROJECT_REF}" not in url:
                errors.append("supabase-dev MCP must use ${SUPABASE_PROJECT_REF}")
            if "read_only=true" not in url:
                errors.append("supabase-dev MCP must remain read_only=true")

    if "gitnexus-recruitment" not in servers:
        errors.append(".omp/mcp.json requires gitnexus-recruitment")


def validate_legacy_markers(errors: list[str]) -> None:
    for path in CORE_GOVERNANCE_PATHS:
        if not path.is_file():
            errors.append(f"missing core governance file: {path.relative_to(ROOT)}")
            continue

        text = path.read_text(encoding="utf-8")
        for marker in LEGACY_RUNTIME_MARKERS:
            if marker in text:
                errors.append(
                    f"{path.relative_to(ROOT)} still contains legacy runtime marker {marker!r}"
                )

    old_review_skill = OMP_ROOT / "skills" / "eiu-code-review" / "SKILL.md"
    if old_review_skill.exists():
        errors.append("legacy .omp/skills/eiu-code-review/SKILL.md must remain removed")

    lock_text = LOCK_PATH.read_text(encoding="utf-8") if LOCK_PATH.is_file() else ""
    machine_path_patterns = (
        r"[A-Za-z]:[/\\]Users[/\\][^/\\\s]+",
        r"/Users/[^/\s]+/",
        r"/home/[^/\s]+/",
    )
    for pattern in machine_path_patterns:
        if re.search(pattern, lock_text):
            errors.append("SKILLS_LOCK.yaml contains a machine-specific user-home path")
            break


def main() -> int:
    errors: list[str] = []

    project_skills = collect_project_skills(errors)
    validate_config(errors)
    validate_agents(project_skills, errors)
    validate_registry(project_skills, errors)
    validate_mcp(errors)
    validate_legacy_markers(errors)

    required_project_skill = "verification-before-completion"
    if required_project_skill not in project_skills:
        errors.append(f"missing required project-local skill {required_project_skill}")

    if errors:
        print("AGENT SETUP VALIDATION: FAIL")
        for error in errors:
            print(f" - {error}")
        return 1

    print("AGENT SETUP VALIDATION: PASS")
    print(f" - project skills: {len(project_skills)}")
    print(f" - project agents: {len(EXPECTED_AGENTS)}")
    print(" - todo.eager: always")
    print(" - skill runtime: OMP_NATIVE_DISCOVERY")
    print(" - machine-specific runtime skill paths: none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
