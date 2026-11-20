#!/usr/bin/env python3
"""Generate the Tier 2 dynamic card JSON for KubeStellar Console.

Usage: CONSOLE_ORIGIN=https://console.example.com python3 build-card.py
"""
from __future__ import annotations

import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
origin = os.environ.get("CONSOLE_ORIGIN", "https://console.example.com").rstrip("/")
source = (HERE / "src/card.tsx").read_text().replace("{{CONSOLE_ORIGIN}}", origin)

card = {
    "id": "mjolnir-bootc-fleet",
    "title": "Mjolnir bootc Fleet",
    "description": "bootc image version, pending updates, reboot locks and WiFi state for Mjolnir nodes",
    "tier": "tier2",
    "icon": "Server",
    "iconColor": "text-sky-400",
    "defaultWidth": 12,
    "createdAt": "2026-11-19T00:00:00Z",
    "updatedAt": "2026-11-19T00:00:00Z",
    "sourceCode": source,
}

out = HERE / "card.json"
out.write_text(json.dumps(card, indent=2) + "\n")
print(f"wrote {out} (endpoint origin: {origin})")
