# MISCELLANEA OF PS scripts (almost all AI Generated, why... why not? -_-)

## `rag-docs-downloader.ps1`

A technical documentation scraper for the [big-rag](https://lmstudio.ai/mindstudio/big-rag) plugin in LM Studio that incrementally downloads — via sparse-checkout and partial clone — only the files readable by the plugin from a set of curated GitHub repositories, keeping them up-to-date and confined to a dedicated local location.

⚠️ BE CARE TO SETUP A RIGHT PATH...

Configuration is defined in `rag-docs.toml` (must be in the same folder as the script)

You need to populate the .toml file to make the script work:
+ `[paths].base` : define your path **(the script works only inside this path and recursively)**
+ `[[repos]]` : define which GitHub repositories to clone for documentation
+ `[filter.include]` : whitelist of folder names to keep (e.g. `docs`, `api`, `guide`)
+ `[filter.exclude]` : folder names and file extensions to discard

**Known Issues:**
+ in TOML file, problem specific to `#` in value, because the parser strips everything after `#` as an inline comment. **esample:** `"C# language spec"` becomes `"C after the parse."`, only notes containing `#` should be single quoted: `tomlnote = 'C# language spec'`
