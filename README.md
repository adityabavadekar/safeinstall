# safeinstall

Block dangerous install scripts and source builds during package installation.

Commands like `npm install` and `pip install` automatically run postinstall/preinstall scipts that can steal files or download malware.

`safeinstall` installs lightweight wrappers around package managers to enforce safer defaults.


## Installation

```bash
curl -fSL https://raw.githubusercontent.com/adityabavadekar/safeinstall/master/safeinstall.sh | bash -s -- setup
```


## Commands

```bash
safeinstall help
safeinstall setup
safeinstall status
safeinstall remove
```


## How It Works


Setup will:
1. Install package manager wrappers
2. Prepend `~/.local/bin` to `PATH`
3. Intercept install commands
4. Apply safer install policies automatically
5. Warn on blocked script execution or source builds


## Overrides

Use the `unsafe-` prefix:

```bash
unsafe-npm install
unsafe-pip install .
unsafe-[package-manager] [install args]
````

Or invoke the real binary directly:

```bash
/usr/bin/npm install
```


## Supported Package Managers

* **Node.js**: `npm`, `pnpm`, `yarn`, `bun`, `npx`, `bunx`
* **Python**: `pip`, `pip3`, `uv`, `uvx`

