#!/usr/bin/env bash
# Bloquea los grupos LAMA/YTS/Kitsune solo para The Odyssey (2026),
# que comparte título y año con una película de bajo presupuesto.
# Crea un tag en Radarr, lo asigna a la película, y crea un Release
# Profile scoped a ese tag. Idempotente: seguro volver a ejecutar.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }

STORAGE=$(grep -m1 "^STORAGE=" "$ENV_FILE" | cut -d= -f2-)
RADARR_KEY=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$STORAGE/config/radarr/config.xml" | sed "s/<[^>]*>//g")
API="http://localhost:7878/api/v3"
TAG_LABEL="odyssey-lowbudget-block"
# Grupos que suben la versión de bajo presupuesto
IGNORED='["LAMA","YTS","Kitsune"]'

radarr() { curl -sf -H "X-Api-Key: $RADARR_KEY" -H "Content-Type: application/json" "$@"; }

# 1. Crear o reutilizar el tag
TAG_ID=$(radarr "$API/tag" | python3 -c "
import json,sys
tags=json.load(sys.stdin)
t=next((t for t in tags if t['label']=='$TAG_LABEL'),None)
print(t['id'] if t else '')
")
if [[ -z $TAG_ID ]]; then
    TAG_ID=$(radarr -X POST "$API/tag" -d "{\"label\":\"$TAG_LABEL\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    echo "Tag '$TAG_LABEL' creado (id=$TAG_ID)"
else
    echo "Tag '$TAG_LABEL' ya existe (id=$TAG_ID)"
fi

# 2. Buscar The Odyssey (2026)
MOVIE_ID=$(radarr "$API/movie" | python3 -c "
import json,sys
movies=json.load(sys.stdin)
m=next((m for m in movies if m['title'].lower()=='the odyssey' and m.get('year')==2026),None)
print(m['id'] if m else '')
")
[[ -n $MOVIE_ID ]] || { echo "ERROR: The Odyssey (2026) no encontrada en Radarr — ¿está añadida?"; exit 1; }

# 3. Añadir el tag a la película (sin pisar los tags que ya tenga)
UPDATED=$(radarr "$API/movie/$MOVIE_ID" | python3 -c "
import json,sys
m=json.load(sys.stdin)
if $TAG_ID not in m.get('tags',[]):
    m['tags']=m.get('tags',[])+[$TAG_ID]
print(json.dumps(m))
")
radarr -X PUT "$API/movie/$MOVIE_ID" -d "$UPDATED" > /dev/null
echo "Tag asignado a The Odyssey (2026) (movie_id=$MOVIE_ID)"

# 4. Crear el release profile si no existe
if radarr "$API/releaseprofile" | python3 -c "
import json,sys
profiles=json.load(sys.stdin)
exit(0 if any(p.get('name')=='$TAG_LABEL' for p in profiles) else 1)
" 2>/dev/null; then
    echo "Release profile '$TAG_LABEL' ya existe, no lo toco."
else
    radarr -X POST "$API/releaseprofile" \
        -d "{\"name\":\"$TAG_LABEL\",\"enabled\":true,\"required\":[],\"ignored\":$IGNORED,\"indexerId\":0,\"tags\":[$TAG_ID]}" \
        > /dev/null
    echo "Release profile creado: bloquea $IGNORED solo para películas con tag '$TAG_LABEL'"
fi

echo "Listo."
