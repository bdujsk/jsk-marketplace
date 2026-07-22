# jsk-marketplace

Private GitHub Copilot CLI plugin marketplace.

## Structure

```
<plugin-name>/
├── plugin.json          ← plugin metadata + skills path
└── skills/
    └── <skill-name>/
        └── SKILL.md     ← skill content (YAML frontmatter + markdown)
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [oc-dr](./oc-dr/) | OpenShift Disaster Recovery using Velero/OADP |

## Installation

Add to `~/.copilot/settings.json`:

```json
"extraKnownMarketplaces": {
  "jsk-marketplace": {
    "source": {
      "source": "github",
      "repo": "YOUR_GITHUB_USERNAME/jsk-marketplace"
    }
  }
},
"enabledPlugins": {
  "oc-dr@jsk-marketplace": true
}
```

Then from the CLI run `/plugin install oc-dr@jsk-marketplace` or restart Copilot CLI.
