#!/bin/zsh
# Penny, Little Wallet's helper, drawn by Codex in the app's stitched-leather style. ~5 min each.
cd "${0:A:h}"
mkdir -p out/items logs
CHAR="Penny is a small, chubby, friendly character: a forest-green (#3F6953) stitched leather bifold wallet with a \
round soft body, a cream card peeking out of the top like a little hat, big warm dark eyes with tiny white \
highlights, rosy peach cheeks, a gentle smile, a small peach (#E8875A) bow tie, a tiny butter-yellow headset with \
a little microphone like a hotel receptionist, short stubby felt arms. Same soft tactile 3D felt-and-leather look, \
stitching and warm studio light as the attached icons. Kind and welcoming, never creepy, no human features beyond the face. \
Background: one perfectly flat, uniform pure magenta (#FF00FF) everywhere around the character, no gradient, no \
floor, no cast shadow on the background. Nothing in the character is magenta or pink. No text."
typeset -A P
P[penny-hello]="Full body, front three-quarter view, waving hello with one arm raised, happy open smile. Centred, filling about 80% of a square 1024x1024 image. $CHAR"
P[penny-checking]="Full body, holding a small cream paper receipt in both arms and reading it attentively, one eyebrow slightly raised, a tiny magnifying glass tucked under one arm. Centred, filling about 80% of a square 1024x1024 image. $CHAR"
P[penny-face]="Head-and-shoulders portrait, looking straight at the viewer with a warm smile, the face large and centred so it reads well in a small circle. Square 1024x1024. $CHAR"
for name in ${(k)P}; do
  prompt="Use your image generation tool to create this image, then save the final PNG to out/items/$name.png in the current directory (overwrite it if it exists). Do not write any code or other files. ${P[$name]}"
  codex exec --skip-git-repo-check -s workspace-write -C "$PWD" -i out/icon.png -i out/items/cat-groceries.png -- "$prompt" < /dev/null > logs/$name.log 2>&1 &
  echo "started $name"
done
wait
for name in ${(k)P}; do [[ -f out/items/$name.png ]] && echo "done  $name" || echo "MISSING $name"; done
