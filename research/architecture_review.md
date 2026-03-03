# Architecture Review: `self.users.[name]`

We have implemented a **"Top-Level Output"** pattern for user modules. Here is a critical breakdown of why we chose this, how it compares to alternatives, and its long-term viability.

---

## 🏗️ The Approach: `self.users.[name]`

**Mechanism**:
1. `users/default.nix` acts as a registry, mapping strings ("inkpotmonkey") to file paths.
2. `flake.nix` calls this registry and exposes the result as a Top-Level Output called `users`.
3. Hosts import `self.users.inkpotmonkey` directly.

### ✅ Pros (Why it’s Good)
*   **Zero "Module Magic"**: We avoid `nixosModules` wrapping complexities. You are literally just passing a file path to the host's `modules` list.
*   **Dot-Notation Ergonomics**: `self.users.inkpotmonkey` is readable and suggests ownership.
*   **Encapsulation**: The host does not know *where* the file lives on disk (`users/inkpotmonkey/system.nix`). This allows you to refactor the internal folder structure of `users/` without breaking every host config.
*   **Portability**: Because the user is a standalone module, it can be tested or imported in isolation easier than if it were tightly coupled to the host via options.

### ⚠️ Cons (The Trade-offs)
*   **Manual Registration**: You must remember to add new users to `users/default.nix`. (vs. auto-discovery).
*   **Non-Standard Output**: `users` is not a standard flake output like `packages` or `nixosModules`. CLI tools like `nix search` won't know what to do with it (but that matters less for private configs).

---

## 🆚 Comparison with Other Approaches

### 1. The "Path" Approach (Previous)
*   **Syntax**: `(self + /users/inkpotmonkey/system.nix)`
*   **Verdict**: **Inferior**. It treats the file system as the API. Moving a file breaks code. It looks "messy" in configuration files.

### 2. The "Option" Approach (NixOS Enterprise)
*   **Syntax**: `my.users.inkpotmonkey.enable = true;`
*   **How it differs**: This treats users as *features* of the system, not modules. You would write a complex module that defines options (`options.my.users...`) and then uses `config` to apply them.
*   **Verdict**: **Overkill**. Great if you have 500 servers and want to toggle users via a boolean key-value pair. Excessive boilerplate for a personal cluster.

### 3. The "Snowfall / Haumea" Approach (Library)
*   **Syntax**: Automatic (Implicit)
*   **How it differs**: These libraries recursively scan your directories and auto-wire everything.
*   **Verdict**: **Magic Black Box**. It saves you writing `users/default.nix`, but if something breaks, debugging the library's internal recursion is painful. Our approach is "Explicit is better than Implicit."

---

## 🎯 Conclusion

The **Top-Level Output (`self.users`)** approach is the **Sweet Spot** for personal and semi-professional clusters.
It provides the **cleanliness** of the Enterprise approach without the **boilerplate**, and the **explicitness** of the Path approach without the **fragility**.

It is a standard, robust, "Pure Nix" solution that will not break with future Nix versions.
