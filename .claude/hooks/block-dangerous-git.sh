#!/bin/bash
# Blocca i comandi git distruttivi prima che vengano eseguiti (hook PreToolUse).
# Versione con pattern regex, derivata da mattpocock/skills
# (skills/misc/git-guardrails-claude-code). L'originale con match a sottostringa
# e' in block-dangerous-git.sh.orig.
#
# Rispetto all'originale questa versione:
#   - riconosce i flag globali di git tra `git` e il sottocomando (`git -C . push`)
#   - tollera spaziatura variabile (`git   push`)
#   - non scatta su una stringa citata (`echo 'git push'`), perche' pretende che
#     `git` stia a inizio comando o subito dopo un separatore di shell
#
# NB: e' una rete contro l'errore distratto, non una barriera di sicurezza.
# Chi vuole aggirarla ha comunque strada (variabili, eval, script esterni).

INPUT=$(cat)

# Estrae il comando. jq se c'e', altrimenti python3 (usato dagli altri hook del
# progetto): mai fallire in silenzio lasciando passare tutto.
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
elif command -v python3 >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))')
else
  echo "BLOCKED: ne' jq ne' python3 disponibili, impossibile verificare il comando." >&2
  exit 2
fi

[ -z "$COMMAND" ] && exit 0

# --- Mattoni della regex --------------------------------------------------

# Inizio di un comando vero: inizio riga, oppure dopo ; & | && || ( ) { } `
SEP='(^|[;&|(){}`]|&&|\|\|)[[:space:]]*'

# Wrapper opzionali davanti a git.
WRAP='((sudo|env|command|nohup|time)[[:space:]]+)*'

# `git` piu' i suoi flag globali, ciascuno con un eventuale valore:
# copre -C <path>, -c <k=v>, --git-dir=<p>, --work-tree <p>, --no-pager...
GIT='git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+'

# Prefisso completo: un'invocazione git fino al sottocomando.
G="${SEP}${WRAP}${GIT}"

# Resto degli argomenti dello stesso comando (non attraversa ; & |).
A='[^;&|]*'

# --- Pattern bloccati -----------------------------------------------------
# Formato: "etichetta leggibile|regex"

DANGEROUS=(
  "git push|${G}push([[:space:]]|\$)"
  "git reset --hard|${G}reset[[:space:]]${A}--hard"
  "git clean -f|${G}clean[[:space:]]${A}-[a-zA-Z]*f"
  "git branch -D|${G}branch[[:space:]]${A}-[a-zA-Z]*D"
  "git checkout .|${G}checkout[[:space:]]${A}\\.([[:space:]]|\$)"
  "git restore .|${G}restore[[:space:]]${A}\\.([[:space:]]|\$)"
)

for entry in "${DANGEROUS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  if printf '%s' "$COMMAND" | grep -qE "$regex"; then
    echo "BLOCKED: '$COMMAND' matches dangerous pattern '$label'. The user has prevented you from doing this." >&2
    exit 2
  fi
done

exit 0
