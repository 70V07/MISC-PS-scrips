# MISCELLANEA OF PS Scripts (almost all AI Generated, why... why not? -_-)

+ `big-rag_docu.ps1` ─ A technical documentation scraper for the big-rag plugin in LM Studio that incrementally downloads — via sparse-checkout and partial clone — only the files readable by the plugin from a set of curated GitHub repositories, keeping them up-to-date and confined to a dedicated local location.

`$PATH` : define your path (the script work only inside this path and recursevly)
`$REPOS` : define which GitHub you need to clone for download documentations
`$ALLOWED_EXT` : this shouldnt be changed, but if need remove a format that you dont want big-rag to read...
