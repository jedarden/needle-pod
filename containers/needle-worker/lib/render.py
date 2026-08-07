#!/usr/bin/env python3
"""Render provider credentials into every harness's native config format.

The whole point of this file: a provider is described *once*, in environment
variables sourced from a Kubernetes Secret, and fanned out into the seven
different config shapes the harnesses actually read. Adding a provider is an
env change, not a code change; adding a harness is one function here plus an
adapter template.

SECRETS ARE NEVER WRITTEN TO DISK. Every harness supports indirection to an
environment variable, so the rendered files carry the *name* of the variable
holding the token, never its value:

    codex     env_key = "NEEDLE_PROVIDER_GLM_TOKEN"
    opencode  "apiKey": "{env:NEEDLE_PROVIDER_GLM_TOKEN}"
    droid     "apiKey": "${NEEDLE_PROVIDER_GLM_TOKEN}"
    claude/pi/goose/aider  read their env vars directly at invoke time

That property is load-bearing. A pod whose filesystem is dumped, or whose
emptyDir survives into a debug container, leaks no credential.

Input contract (see docs/notes/worker-image.md):

    NEEDLE_POD_PROVIDERS         glm anthropic          (comma or space list)
    NEEDLE_POD_DEFAULT_PROVIDER  glm
    NEEDLE_POD_HARNESSES         claude-code codex ...

    NEEDLE_PROVIDER_<NAME>_KIND               anthropic | openai
    NEEDLE_PROVIDER_<NAME>_BASE_URL           https://api.z.ai/api/anthropic
    NEEDLE_PROVIDER_<NAME>_TOKEN              (the secret itself)
    NEEDLE_PROVIDER_<NAME>_MODEL              glm-5
    NEEDLE_PROVIDER_<NAME>_SMALL_MODEL        glm-4.7        (optional)
    NEEDLE_PROVIDER_<NAME>_MAX_OUTPUT_TOKENS  65536          (optional)
    NEEDLE_PROVIDER_<NAME>_DISPLAY_NAME       GLM 5          (optional)
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME", "/home/needle"))
NEEDLE_HOME = Path(os.environ.get("NEEDLE_HOME", HOME / ".needle"))
SHARE = Path(os.environ.get("NEEDLE_POD_SHARE", "/usr/local/share/needle-pod"))

ALL_HARNESSES = ["claude-code", "codex", "opencode", "pi", "droid", "goose", "aider"]


def log(level: str, message: str, **extra) -> None:
    rec = {"level": level, "component": "needle-pod-render", "message": message}
    rec.update(extra)
    print(json.dumps(rec), file=sys.stderr)


def env_key(name: str) -> str:
    """glm-4.7 -> GLM_4_7, matching common.sh's upper_snake()."""
    return re.sub(r"_+$", "", re.sub(r"[^A-Z0-9_]", "_", name.upper().replace("-", "_")))


def split_list(raw: str | None) -> list[str]:
    return [x for x in re.split(r"[,\s]+", (raw or "").strip()) if x]


class Provider:
    """One upstream inference endpoint, however it is billed."""

    def __init__(self, name: str):
        self.name = name
        k = env_key(name)
        self.var_prefix = f"NEEDLE_PROVIDER_{k}"
        self.token_var = f"{self.var_prefix}_TOKEN"

        def get(suffix: str, default: str = "") -> str:
            return os.environ.get(f"{self.var_prefix}_{suffix}", default).strip()

        self.kind = (get("KIND") or "anthropic").lower()
        self.base_url = get("BASE_URL")
        # A provider commonly serves BOTH wire protocols at different paths —
        # Z.AI exposes an Anthropic-shaped API at /api/anthropic and an
        # OpenAI-shaped one at /api/paas/v4. Harnesses that only speak the
        # OpenAI wire need the second URL; a single base_url cannot express it.
        self.openai_base_url = get("OPENAI_BASE_URL")
        self.model = get("MODEL")
        self.small_model = get("SMALL_MODEL") or self.model
        self.display_name = get("DISPLAY_NAME") or name
        self.max_output_tokens = get("MAX_OUTPUT_TOKENS") or "32768"
        self.has_token = bool(os.environ.get(self.token_var, "").strip())

    def validate(self) -> list[str]:
        problems = []
        if self.kind not in ("anthropic", "openai"):
            problems.append(f"{self.var_prefix}_KIND must be 'anthropic' or 'openai', got {self.kind!r}")
        if not self.model:
            problems.append(f"{self.var_prefix}_MODEL is required")
        if not self.has_token:
            problems.append(f"{self.token_var} is unset — mount it from the provider Secret")
        # base_url is genuinely optional: an unset value means the harness's
        # own default endpoint, which is correct for first-party Anthropic or
        # OpenAI keys.
        return problems

    @property
    def chat_completions_url(self) -> str:
        """OpenAI-wire base URL, for harnesses that only speak that shape.

        Falls back to base_url only when the provider is openai-kind. For an
        anthropic-kind provider, base_url points at an Anthropic-shaped path
        and handing it to an OpenAI-wire client produces 404s at dispatch —
        so OPENAI_BASE_URL must be set explicitly for those harnesses to work.
        """
        if self.openai_base_url:
            return self.openai_base_url
        if self.kind == "openai" and self.base_url:
            return self.base_url
        return "https://api.openai.com/v1" if self.kind == "openai" else "https://api.anthropic.com/v1"

    @property
    def has_openai_wire(self) -> bool:
        """Whether an OpenAI-wire endpoint is actually known for this provider."""
        return bool(self.openai_base_url) or self.kind == "openai"


# --------------------------------------------------------------------------
# Minimal TOML / YAML emitters.
#
# The image carries no tomli-w or PyYAML, and adding them to pull in two
# writers for a handful of flat tables is not worth the dependency. Both
# emitters below are deliberately narrow: strings, ints, bools, and flat
# maps/lists, which is all these configs contain.
# --------------------------------------------------------------------------

def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def yaml_scalar(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    # Quote anything that could be misread as a non-string YAML scalar.
    if s == "" or re.search(r"[:#\{\}\[\],&*?|<>=!%@`\"']", s) or s.strip() != s:
        return "'" + s.replace("'", "''") + "'"
    if s.lower() in ("true", "false", "null", "yes", "no", "on", "off", "~"):
        return "'" + s + "'"
    if re.fullmatch(r"-?\d+(\.\d+)?([eE][-+]?\d+)?", s):
        return "'" + s + "'"
    return s


def yaml_dump(obj, indent: int = 0) -> str:
    pad = "  " * indent
    out = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            if isinstance(value, (dict, list)) and value:
                out.append(f"{pad}{key}:")
                out.append(yaml_dump(value, indent + 1))
            elif isinstance(value, (dict, list)):
                out.append(f"{pad}{key}: {'{}' if isinstance(value, dict) else '[]'}")
            else:
                out.append(f"{pad}{key}: {yaml_scalar(value)}")
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)):
                rendered = yaml_dump(item, indent + 1).lstrip()
                out.append(f"{pad}- {rendered}")
            else:
                out.append(f"{pad}- {yaml_scalar(item)}")
    return "\n".join(out)


def write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if content.endswith("\n") else content + "\n")
    path.chmod(mode)
    log("info", "wrote config", path=str(path))


# --------------------------------------------------------------------------
# Per-harness config writers
# --------------------------------------------------------------------------

def configure_codex(providers: list[Provider], default: Provider) -> None:
    """~/.codex/config.toml — model_providers keyed by provider name.

    env_key names the variable holding the token, so config.toml stays
    secret-free.
    """
    lines = [
        "# Generated by needle-pod at container start. Do not edit in-pod;",
        "# change the provider Secret/ConfigMap and restart.",
        "",
        f"model = {toml_str(default.model)}",
        f"model_provider = {toml_str(default.name)}",
        'approval_policy = "never"',
        'sandbox_mode = "danger-full-access"',
        "",
    ]
    for p in providers:
        # Codex 0.147 accepts ONLY wire_api = "responses"; "chat" is rejected
        # with "no longer supported" and "anthropic" was never a variant. That
        # means codex requires an endpoint implementing OpenAI's Responses API,
        # which most BYOK/subscription gateways do not. If the provider has no
        # OpenAI-wire endpoint at all, say so rather than emitting a table that
        # will 404 at dispatch.
        if not p.has_openai_wire:
            log("warn", "codex needs an OpenAI Responses-API endpoint; "
                        "provider has no OpenAI-wire URL, so this provider will not dispatch",
                provider=p.name, hint=f"set {p.var_prefix}_OPENAI_BASE_URL")
        lines += [
            f"[model_providers.{p.name}]",
            f"name = {toml_str(p.display_name)}",
            f"base_url = {toml_str(p.chat_completions_url)}",
            f"env_key = {toml_str(p.token_var)}",
            'wire_api = "responses"',
            "",
        ]
    write(HOME / ".codex" / "config.toml", "\n".join(lines))


def configure_opencode(providers: list[Provider], default: Provider) -> None:
    """~/.config/opencode/opencode.json — {env:VAR} indirection for the key."""
    cfg = {
        "$schema": "https://opencode.ai/config.json",
        "model": f"{default.name}/{default.model}",
        "provider": {},
    }
    for p in providers:
        models = {p.model: {"name": f"{p.display_name} ({p.model})"}}
        if p.small_model != p.model:
            models[p.small_model] = {"name": f"{p.display_name} ({p.small_model})"}
        cfg["provider"][p.name] = {
            # openai-compatible covers /v1/chat/completions, which is what every
            # BYOK endpoint in this fleet exposes.
            "npm": "@ai-sdk/openai-compatible",
            "name": p.display_name,
            "options": {
                "baseURL": p.chat_completions_url,
                "apiKey": "{env:" + p.token_var + "}",
            },
            "models": models,
        }
    write(HOME / ".config" / "opencode" / "opencode.json", json.dumps(cfg, indent=2))


def configure_droid(providers: list[Provider], default: Provider) -> None:
    """~/.factory/settings.json — customModels[], ${VAR} indirection.

    settings.json takes priority over the legacy config.json, and only
    settings.json supports ${VAR} expansion for apiKey.
    """
    custom = []
    for p in providers:
        custom.append({
            "model": p.model,
            "displayName": f"{p.display_name} ({p.model})",
            "baseUrl": p.base_url or p.chat_completions_url,
            "apiKey": "${" + p.token_var + "}",
            "provider": p.kind if p.kind in ("anthropic", "openai") else "generic-chat-completion-api",
            "maxOutputTokens": int(p.max_output_tokens),
        })
    write(HOME / ".factory" / "settings.json", json.dumps({"customModels": custom}, indent=2))


def configure_goose(providers: list[Provider], default: Provider) -> None:
    """~/.config/goose/config.yaml.

    GOOSE_DISABLE_KEYRING is exported by the entrypoint rather than set here —
    goose only checks whether the variable is set, and a pod has no D-Bus
    keyring to fall back on.
    """
    cfg = {
        "GOOSE_PROVIDER": default.name,
        "GOOSE_MODEL": default.model,
        "GOOSE_MODE": "auto",
    }
    write(HOME / ".config" / "goose" / "config.yaml", yaml_dump(cfg))


def configure_aider(providers: list[Provider], default: Provider) -> None:
    """~/.aider.conf.yml — flags only; keys come from the environment."""
    prefix = "anthropic/" if default.kind == "anthropic" else "openai/"
    cfg = {
        "model": f"{prefix}{default.model}",
        "yes-always": True,
        "no-pretty": True,
        "no-auto-commits": True,   # NEEDLE owns the commit; see features.md
        "no-analytics": True,
        "no-check-update": True,
    }
    if default.base_url:
        cfg["openai-api-base" if default.kind == "openai" else "anthropic-api-base"] = default.base_url
    write(HOME / ".aider.conf.yml", yaml_dump(cfg))


def configure_pi(providers: list[Provider], default: Provider) -> None:
    """pi reads standard provider env vars (its own containerization guide
    passes ANTHROPIC_API_KEY straight through), so there is nothing to write.
    The env file produced by write_provider_env() is what pi consumes.
    """
    (HOME / ".pi").mkdir(parents=True, exist_ok=True)


def configure_claude_code(providers: list[Provider], default: Provider) -> None:
    """Claude Code is configured entirely through the env vars set on the
    adapter's invoke line, matching the bare-metal GLM adapters. Nothing on disk.
    """
    return


HARNESS_CONFIGURERS = {
    "claude-code": configure_claude_code,
    "codex": configure_codex,
    "opencode": configure_opencode,
    "pi": configure_pi,
    "droid": configure_droid,
    "goose": configure_goose,
    "aider": configure_aider,
}


# --------------------------------------------------------------------------
# NEEDLE adapters
# --------------------------------------------------------------------------

def render_adapters(harnesses: list[str], providers: list[Provider]) -> list[str]:
    """One adapter per (harness, provider) pair, from the templates baked into
    the image. Templates use @@NAME@@ placeholders — NEEDLE's own ${WORKSPACE}
    and ${PROMPT} must survive substitution untouched.
    """
    # ~/.config/needle/adapters is what NEEDLE actually loads (it is
    # agent.adapters_dir, and the live bare-metal config points there).
    # NOT ~/.needle/agents — that directory exists on the bare-metal box, is
    # full of adapters, and is read by nothing. Writing there produces a worker
    # that claims a bead and then dies at dispatch with "configured agent
    # adapter not found", leaving the bead claimed. The error message itself
    # names ~/.needle/agents, which is what makes this so easy to get wrong.
    agents_dir = Path(os.environ.get("NEEDLE_ADAPTERS_DIR", str(HOME / ".config" / "needle" / "adapters")))
    agents_dir.mkdir(parents=True, exist_ok=True)
    written = []

    for harness in harnesses:
        template_path = SHARE / "adapters" / f"{harness}.yaml.tmpl"
        if not template_path.exists():
            log("warn", "no adapter template for harness; skipping", harness=harness)
            continue
        template = template_path.read_text()

        for p in providers:
            name = f"{harness}-{p.name}"
            # Whole env-assignment blocks, not bare values. invoke_template is a
            # single-line shell string, so an unset base URL substituted into
            # `ANTHROPIC_BASE_URL='@@BASE_URL@@'` would export an empty endpoint
            # and override the harness's own default. Emitting the entire
            # assignment (or nothing) makes that unrepresentable.
            # Bare $VAR, not "$VAR". invoke_template is a double-quoted YAML
            # scalar, so an inner double quote terminates it and the adapter
            # fails to parse. Provider tokens are alphanumeric, so there is no
            # word-splitting risk from leaving them unquoted.
            anthropic_env = [
                f"ANTHROPIC_AUTH_TOKEN=${p.token_var}",
                f"ANTHROPIC_API_KEY=${p.token_var}",
                f"ANTHROPIC_MODEL='{p.model}'",
                f"ANTHROPIC_DEFAULT_OPUS_MODEL='{p.model}'",
                f"ANTHROPIC_DEFAULT_SONNET_MODEL='{p.model}'",
                f"ANTHROPIC_DEFAULT_HAIKU_MODEL='{p.small_model}'",
                f"CLAUDE_CODE_SUBAGENT_MODEL='{p.small_model}'",
                "DISABLE_AUTOUPDATER=1",
                "DISABLE_TELEMETRY=1",
            ]
            if p.base_url:
                anthropic_env.insert(0, f"ANTHROPIC_BASE_URL='{p.base_url}'")

            openai_env = [f"OPENAI_API_KEY=${p.token_var}", f"OPENAI_MODEL='{p.model}'"]
            if p.has_openai_wire:
                openai_env.insert(0, f"OPENAI_BASE_URL='{p.chat_completions_url}'")

            subs = {
                "ADAPTER_NAME": name,
                "PROVIDER": p.name,
                "PROVIDER_DISPLAY": p.display_name,
                "MODEL": p.model,
                "SMALL_MODEL": p.small_model,
                "TOKEN_VAR": p.token_var,
                "MAX_OUTPUT_TOKENS": p.max_output_tokens,
                "TIMEOUT_SECS": os.environ.get("NEEDLE_POD_AGENT_TIMEOUT", "3600"),
                "ANTHROPIC_ENV": " ".join(anthropic_env),
                "OPENAI_ENV": " ".join(openai_env),
            }
            body = template
            for key, value in subs.items():
                body = body.replace(f"@@{key}@@", str(value))

            # Drop env assignments whose value substituted to nothing.
            #
            # BASE_URL is legitimately unset for a first-party Anthropic or
            # OpenAI key, and leaving `ANTHROPIC_BASE_URL= \` in the invoke line
            # would export an *empty* endpoint — overriding the harness's own
            # default with something unusable, which fails at dispatch rather
            # than at startup. Removing the whole line keeps the backslash
            # continuation chain intact.
            body = "\n".join(
                line for line in body.split("\n")
                if not re.fullmatch(r"\s*[A-Za-z_][A-Za-z0-9_]*=\s*\\?\s*", line)
            )

            leftover = re.findall(r"@@[A-Z_]+@@", body)
            if leftover:
                log("error", "adapter template has unsubstituted placeholders",
                    harness=harness, placeholders=sorted(set(leftover)))
                continue

            (agents_dir / f"{name}.yaml").write_text(body)
            written.append(name)

    # stream-parser.sh is referenced by the claude-code adapter as
    # ${AGENT_DIR}/stream-parser.sh; ship the copy that came with the image.
    parser_src = SHARE / "adapters" / "stream-parser.sh"
    if parser_src.exists():
        dest = agents_dir / "stream-parser.sh"
        dest.write_text(parser_src.read_text())
        dest.chmod(0o755)

    return written


def write_provider_env(providers: list[Provider], default: Provider) -> None:
    """A sourceable env file for harnesses that read conventional variables.

    It exports only variable *names* that already exist in the environment —
    the values come from the pod's Secret-backed env, so this file contains no
    credential of its own.
    """
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by needle-pod. Sourced by adapters that read conventional",
        "# provider env vars. Contains no secret values — only re-exports.",
        "",
        "export GOOSE_DISABLE_KEYRING=1",
        f'export GOOSE_PROVIDER="{default.name}"',
        f'export GOOSE_MODEL="{default.model}"',
        "",
    ]
    if default.kind == "anthropic":
        lines += [
            f'export ANTHROPIC_AUTH_TOKEN="${{{default.token_var}}}"',
            f'export ANTHROPIC_API_KEY="${{{default.token_var}}}"',
            f'export ANTHROPIC_MODEL="{default.model}"',
        ]
        if default.base_url:
            lines.append(f'export ANTHROPIC_BASE_URL="{default.base_url}"')
    else:
        lines += [
            f'export OPENAI_API_KEY="${{{default.token_var}}}"',
            f'export OPENAI_MODEL="{default.model}"',
            f'export OPENAI_BASE_URL="{default.chat_completions_url}"',
        ]
    write(NEEDLE_HOME / "provider-env.sh", "\n".join(lines), mode=0o700)


def main() -> int:
    provider_names = split_list(os.environ.get("NEEDLE_POD_PROVIDERS"))
    if not provider_names:
        log("error", "NEEDLE_POD_PROVIDERS is empty — nothing to configure")
        return 1

    providers = [Provider(n) for n in provider_names]

    problems = [p for prov in providers for p in prov.validate()]
    if problems:
        for p in problems:
            log("error", "provider configuration invalid", detail=p)
        return 1

    default_name = os.environ.get("NEEDLE_POD_DEFAULT_PROVIDER", "").strip() or provider_names[0]
    matches = [p for p in providers if p.name == default_name]
    if not matches:
        log("error", "default provider is not in NEEDLE_POD_PROVIDERS",
            default=default_name, providers=provider_names)
        return 1
    default = matches[0]

    harnesses = split_list(os.environ.get("NEEDLE_POD_HARNESSES")) or ALL_HARNESSES
    unknown = [h for h in harnesses if h not in ALL_HARNESSES]
    if unknown:
        log("error", "unknown harness requested", unknown=unknown, known=ALL_HARNESSES)
        return 1

    for harness in harnesses:
        HARNESS_CONFIGURERS[harness](providers, default)

    write_provider_env(providers, default)
    adapters = render_adapters(harnesses, providers)

    log("info", "provider rendering complete",
        providers=[p.name for p in providers],
        default=default.name,
        harnesses=harnesses,
        adapters=adapters)
    return 0


if __name__ == "__main__":
    sys.exit(main())
