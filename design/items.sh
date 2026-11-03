#!/bin/zsh
# One Codex job per icon or card, so each gets the full image resolution. ~5 min each, 6 at a time.
# Usage: design/items.sh [name ...]   (no names = all)
cd "${0:A:h}"
mkdir -p out/items logs

LOOK="Match the attached sheet's look exactly: soft tactile 3D, stitched leather and felt, warm studio light from \
the top left, palette of forest green #3F6953, cream, peach #E8875A and butter yellow. One single object, centred, \
filling about 80% of a square 1024x1024 image, seen from a slight three-quarter angle. Background: one perfectly flat, \
uniform pure magenta (#FF00FF) everywhere around the object, no gradient, no floor, no cast shadow on the background. \
Nothing in the object is magenta or pink. No text, no logos."
CARD="Match the attached card sheet's look exactly. One single payment card, front view, perfectly flat-on, \
credit-card ratio 1.586:1, filling about 90% of the width of a 1536x1024 image, with a small gold chip and a tiny \
embossed wallet mark in the top right corner, no numbers, no names, no bank or network logos. Background: one \
perfectly flat, uniform pure magenta (#FF00FF) everywhere around the card, no gradient, no shadow on the background. \
Nothing in the card is magenta or pink."

typeset -A P
P[cat-groceries]="A soft paper grocery bag with fresh leafy greens sticking out. $LOOK"
P[cat-dining]="A cheeseburger with a green-sleeved takeaway coffee cup beside it. $LOOK"
P[cat-transport]="A small rounded forest-green car with cream windows and butter-yellow headlights. $LOOK"
P[cat-shopping]="A peach shopping bag with handles and a butter-yellow bow on the front. $LOOK"
P[cat-bills]="A butter-yellow light bulb with a green base leaning on a cream paper bill with stitched lines. $LOOK"
P[cat-fun]="A peach cinema ticket leaning on a green-and-cream striped popcorn box full of popcorn. $LOOK"
P[cat-health]="A cream pill bottle with a ribbed forest-green cap and a stitched peach heart on the label. $LOOK"
P[cat-other]="A curled cream paper receipt with stitched lines and a zigzag torn bottom edge. $LOOK"
P[card-leaf]="Forest green leather card with a soft embossed leaf-and-branch pattern. $CARD"
P[card-pinstripe]="Cream leather card with fine sage-green vertical pinstripes. $CARD"
P[card-wave]="Peach leather card with soft embossed horizontal waves. $CARD"
P[card-stitch]="Deep charcoal-green leather card with a sage stitched border just inside the edge. $CARD"

names=("$@")
(( $#names )) || names=(${(k)P})
running=0
for name in $names; do
  ref=out/categories.png; [[ $name == card-* ]] && ref=out/cards.png
  prompt="Use your image generation tool to create this image, then save the final PNG to out/items/$name.png in \
the current directory (overwrite it if it exists). Do not write any code or other files. ${P[$name]}"
  codex exec --skip-git-repo-check -s workspace-write -C "$PWD" -i $ref -- "$prompt" < /dev/null > logs/$name.log 2>&1 &
  echo "started $name"
  (( ++running % 6 == 0 )) && wait
done
wait
for name in $names; do [[ -f out/items/$name.png ]] && echo "done  $name" || echo "MISSING $name"; done
