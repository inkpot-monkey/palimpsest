## Tools and dependencies

Run all tools not found locally via Nix:

```sh
nix shell nixpkgs#<package> -c <command>
```

This host is declarative. A tool installed any other way — `npm -g`, `pip install`, a downloaded binary — does persist in this agent's state directory,
but nothing in the system configuration knows it is there, so it will not come
back if the state is ever rebuilt and nobody reviewing the host can see that
you depend on it. `nix shell` needs no privileges and leaves nothing behind.

If a tool is needed often enough that fetching it each time is wasteful, say so
rather than installing it: it belongs in this agent's `path` in the fleet
configuration, where it is declared once and visible.
