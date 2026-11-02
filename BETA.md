# Ingest beta: a note for testers

Thank you for trying this. Ingest copies a camera card to your drive, reads both sides back in full, and tells you when the card is safe to format. You're among the first people to use it on real work, which is the point, and also why this page exists.

## What to do

1. Install it. The disk image has a file called **Read Me First** with these same steps.
   1. Drag Ingest to Applications, then open it from there. macOS says it can't be opened. Click **Done**.
   2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
   3. Beside the message about Ingest, click **Open Anyway**, enter your login password, then click **Open**.
   4. On macOS 14 you can skip all that: Control-click the app and choose **Open**.
2. Look in the menu bar. There's no window and no Dock icon, only a card icon that opens the widget. If the bar is full and hides it, open Ingest from Applications again.
3. Say yes when macOS asks whether it may read removable volumes. Each new build asks again.
4. Set up your working drive when it asks. It reads how your folders are organised. exFAT, APFS and HFS+ all work, and FAT32 does up to 4 GB a file.
5. Use it on real cards, alongside whatever you normally do. Please keep doing that.

It leaves two things on your drive: `.ingest`, a hidden folder with your setup and a record of what was copied, and `ascmhl` beside each card's footage, the checksum manifest. Your cards are never written to.

## Which Mac

Ingest has only been tested on macOS 27. macOS 14 and 15 are untested, including the install steps above, though it says macOS 14 or later. If you're on either, please say so when you report anything: the report carries your version, and your Mac is especially useful.

## Please don't rely on it yet

**Don't format a card on this beta's word alone without keeping another copy, until you're told otherwise.** Copy your cards the way you always have, or keep a second copy somewhere. If Ingest says Safe and you format anyway with no other copy, that's more trust than it has earned so far.

Clips aren't played. It proves the bytes match, and a clip that was already broken in camera will match perfectly. Open a few clips, as you normally would.

If a card or the drive comes out, the proof ends. Put the card back in and it reads everything again before it can say Safe, which takes about as long as reading the card once. That's on purpose, not a fault. If the drive is pulled during a copy, the files that copy finished say **Have a look** from then on, even after a full read, because nothing can show the drive finished writing them. A crash does the same. Use Stop instead of pulling the cable. There's no way to clear it on that drive for now: to see Safe, copy the card to another drive, or to this one after deleting that copy first.

Some cameras have never been tested on a real card. The [table in the README](README.md#cameras-by-evidence) says which. Modern RED, Sony X-OCN, Canon cinema cameras and striped BRAW are among them, so if you shoot those, your cards are especially useful and need especially careful watching.

## What to send back

Use **Report a Bug** or **Suggest a Feature** in the `···` menu. **Open GitHub** copies your report and opens a blank page: paste it there and send it. Nothing you typed reaches GitHub until you do. If GitHub says the page can't be found, send what you copied to the person who gave you the app. New beta versions come from them too, so Check for Updates can't find them.

The most useful things to hear about:

- Anything that said Safe when you think it shouldn't have. Please tell us straight away.
- Any card it didn't recognise, or a camera it named wrongly.
- Any message you didn't understand, or anything that made you hesitate.
- What it got wrong about how you organise your drive.
- How long a card took, if it felt slow.

Please don't send file names, client names or footage unless you've been asked. Which camera and which card type are plenty to start with.

## Thank you

Every card you run helps. Being honest about what confused you helps more than being polite about it.
