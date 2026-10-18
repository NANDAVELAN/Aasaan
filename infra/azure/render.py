#!/usr/bin/env python3
"""Render Azure Container Apps YAML template using environment variables.

Usage:
    python render.py [template_path] [output_path]

Defaults:
    template_path: infra/azure/app.template.yaml
    output_path:   infra/azure/app.yaml
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from string import Template


def find_template_variables(template_str: str) -> list[str]:
    """Find all placeholder variable names in the template string."""
    # Matches ${VAR} or $VAR (identifier syntax)
    pattern = re.compile(r"\$(?:\{([A-Za-z0-9_]+)\}|([A-Za-z0-9_]+))")
    vars_found: set[str] = set()
    for m in pattern.finditer(template_str):
        name = m.group(1) or m.group(2)
        if name:
            vars_found.add(name)
    return sorted(vars_found)


def render(template_path: Path, output_path: Path, env_dict: dict[str, str] | None = None) -> Path:
    """Render the template into the output file using env variables."""
    if env_dict is None:
        env_dict = os.environ

    if not template_path.exists():
        print(f"ERROR: Template file not found: {template_path}", file=sys.stderr)
        sys.exit(1)

    template_str = template_path.read_text(encoding="utf-8")
    required_vars = find_template_variables(template_str)

    missing = [var for var in required_vars if not env_dict.get(var)]
    if missing:
        print("ERROR: Missing required environment variables for Azure deployment:", file=sys.stderr)
        for var in missing:
            print(f"  - {var}", file=sys.stderr)
        print("\nPlease export all required variables or provide them in your deployment environment.", file=sys.stderr)
        sys.exit(1)

    tmpl = Template(template_str)
    rendered_str = tmpl.substitute(env_dict)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered_str, encoding="utf-8")
    print(f"Rendered {output_path.name} successfully ({len(required_vars)} variables substituted).")
    return output_path


def main() -> None:
    infra_azure = Path(__file__).resolve().parent
    template_path = Path(sys.argv[1]) if len(sys.argv) > 1 else infra_azure / "app.template.yaml"
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else infra_azure / "app.yaml"

    render(template_path, output_path)


if __name__ == "__main__":
    main()
