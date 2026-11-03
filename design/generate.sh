#!/bin/zsh
# Asks Codex for the first Little Wallet look: one job per image, run side by side, ~5 min each.
# Usage: design/generate.sh [name ...]   (no names = all)
cd "${0:A:h}"
mkdir -p out logs

STYLE="Visual style: the same family as the attached Little Fridge app icon and home screen: soft, rounded, \
tactile 3D clay-and-leather look, gentle studio light, subtle stitching, warm cream background (#F7F2E8), \
sage/forest green (#3F6953) as the main colour, peach (#E8875A) and butter yellow accents, friendly and calm, \
never neon or glossy-corporate. No text unless asked. No real brand logos (no Apple, Visa, Mastercard, PayPal, Venmo)."

typeset -A PROMPTS
PROMPTS[icon]="Create an iOS app icon for 'Little Wallet', the sibling app of the attached Little Fridge icon. \
Subject: a chubby, soft forest-green leather bifold wallet seen from the front, slightly open with a cream card \
and a peach card peeking out, a small cream stitched seam like the fridge icon's door seam, and a tiny peach \
coin badge in the lower right corner in the same spot as the fridge icon's orange badge. Square 1024x1024, the \
rounded-square icon shape filled edge to edge, no transparency, no text. $STYLE"

PROMPTS[home]="Design a high-fidelity iPhone 17 app screen (portrait 1206x2622) for 'Little Wallet', a payments \
tracker and bill splitter. Use the attached Little Fridge home screen for the look (cream background, white \
rounded cards, forest-green accents, rounded bold type) and the attached dark screenshot ONLY for the \
information layout, never its colours or branding. Screen content from top to bottom: status bar 9:41; header \
with a small green wallet app icon, the title 'Little Wallet' and a round '+' button; a big month total '\$1,284.60' \
with 'October spending' under it; a row of eight soft rounded vertical bars, one per category (Groceries, Eating \
out, Transport, Shopping, Bills, Fun, Health, Other) each with a small 3D icon under it; a horizontal strip of \
three small payment cards (green 'Apple Card', cream 'Debit', peach 'Cash'); a 'Settle up' banner 'Sam owes you \
\$14.43'; a list grouped by day ('Today', 'Yesterday') with rows like 'Trader Joe's  Groceries  \$21.65' with a \
small split badge, 'Uber  Transport  \$18.40', 'Blue Bottle Coffee  Eating out  \$6.75'; bottom bar with a big \
green microphone button 'Say it' and a 'Scan receipt' button. Crisp, legible text. $STYLE"

PROMPTS[categories]="Create a sprite sheet of 8 category icons for a payments app, arranged in a 4x2 grid on a \
plain cream background, each icon centred in its own equal cell with generous padding and no labels: \
1 groceries (a little paper grocery bag with greens), 2 eating out (a burger with a coffee cup), 3 transport \
(a small rounded car), 4 shopping (a shopping bag with a bow), 5 bills (a light bulb with a paper bill), \
6 fun (a film ticket and popcorn), 7 health (a pill bottle with a heart), 8 other (a folded receipt). \
Each icon is a cute soft 3D object, consistent lighting, slight top-left light, soft shadow. 2048x1024. $STYLE"

PROMPTS[cards]="Create 4 payment card face designs for a wallet app, arranged in a 2x2 grid on a plain cream \
background, each card a credit-card-shaped rounded rectangle (ratio 1.586:1) with generous space between them: \
1 forest green with a soft embossed leaf pattern, 2 cream with fine sage pinstripes, 3 peach with a soft wave \
pattern, 4 deep charcoal-green with a subtle stitched border. Each card has only a small chip and a tiny wallet \
mark in the corner, no numbers, no names, no bank or network logos. Soft tactile 3D, gentle shadow. 2048x1400. $STYLE"


KEY="Background: one perfectly flat, uniform pure magenta (#FF00FF) everywhere around the objects, with no \
gradient, no texture, no floor and no cast shadow on the background, so the objects can be cut out cleanly. \
Nothing in the objects is magenta or pink."
PROMPTS[categories-key]="Redraw the attached category icon sheet exactly: same 8 icons, same order, same 4x2 \
grid, same designs and colours, 2048x1024. Only change the background. $KEY"
PROMPTS[cards-key]="Redraw the attached card sheet exactly: same 4 cards, same 2x2 grid, same patterns and \
colours, 2048x1400. Only change the background. $KEY"

names=("$@")
(( $#names )) || names=(icon home categories cards)
for name in $names; do
  refs=(-i refs/little-fridge-icon.png)
  [[ $name == home ]] && refs+=(-i refs/little-fridge-home.png -i refs/structure-reference.png)
  [[ $name == categories-key ]] && refs=(-i out/categories.png)
  [[ $name == cards-key ]] && refs=(-i out/cards.png)
  prompt="Use your image generation tool to create this image, then save the final PNG to \
out/$name.png in the current directory (overwrite it if it exists). Do not write any code or other files. \
${PROMPTS[$name]}"
  codex exec --skip-git-repo-check -s workspace-write -C "$PWD" $refs -- "$prompt" < /dev/null > logs/$name.log 2>&1 &
  echo "started $name (pid $!)"
done
wait
for name in $names; do
  [[ -f out/$name.png ]] && echo "done  $name" || echo "MISSING $name (see logs/$name.log)"
done
