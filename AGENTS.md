im an engineer, and i want to build the following experience on macos: a AI-driven copy and pasting experience. Heres how it works. By pressing a key combo (e.g. command + shift + C), you activate the AI copy mode. Then, using the cursor pointer to circle something ( i think this is called lasso select), it copies everything that is circled into a context. On paste, there would be no lasso select, but instead, the user is responsible for selecting and focusing on the input box (so just like how the traditional command + v works) and then trigger AI paste via a special key combo (e.g. shift + command + v). Then, an AI inference is run to decide what to paste based on the copied context, and then finally the right data is pasted across the surface area.

The data pasted can be a strict substring, or even a transformed text. Here is an example for transformed text: let’s say I select an entire text message from my girlfriend saying that she is allergic to onion, garlic, and tomato, e.g. “im allergic to onions and also garlic. Oh dont forget tomatoes as well”. Then, when I go to a restaurant reservation details page that is asking for allergies, the AI paste would intelligently paste a list of allergies (e.g. “garlic, onion, and tomato”), removing any filler and rambling. 

I want you to build a working mpv quickly.

Here are things that I explicitly dont need in the mvp:
- distribution: im going to be the only user running this locally on my Mac, so I dont need to distribute this app to other people on the internet (so no Apple Store, etc.)
- animation: no fancy animation that shows things like AI thinking status
- no true lasso-copy: while the UX for the copy interaction I described is lasso, the actual copied area can be normalized to a rectangle, so its not a true lasso but only an illusion of it
- No standalone UI for the app: the app can just be a tiny swift menu-bar app
- Multi-monitor copy surface area: do not support copying a surface area that spans multiple monitors. But, the copy behavior does need to work on any monitor
- No 100% app coverage: I know that a lot of this work will require exploiting AX, for which some apps work better out of the box and some less well. Thats fine; I dont need 100% app coverage or use case coverage for the mvp

Here are the things that I think should be included or done in a particular way:
- Lasso-copy UI: on lasso copy select, I do want the lasso-ed area to be highlighted with some kind of border to give it a visual cue
- Copy destination context: to make it simple, just take the screenshot of the entire paste destination screen (not just app) to give all the context possible for the AI to make an informed decision. In addition, I think we need to do a custom screenshot post-processing before sending to the AI. Specifically, we need to highlight the paste destination input box with something like a bright red and thick bounding box or an arrow (whatever is easier, more reliable, and unambiguous for the AI). This is the because the traditional macos text caret is insufficient because it is not super visually striking and it flickers, so you can take the screenshot while the flicker is off
- Copy screenshot: if we decide to implement copy as a screenshot (which I prefer), I dont want the user to know that its a screenshot, so there should be no screenshot animation or sound. But if its too hard, then its ok to leave them on

These 2 lists are not meant to be exhaustive, so also use your best judgement on what else to include/exclude.
