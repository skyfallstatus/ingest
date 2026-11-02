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

It leaves two things on your drive: `.ingest`, a hidden folder with your setup and a record of what was copied, and `ascmhl` beside each card it copies, the checksum manifest. A card that was already on the drive gets checked, not copied, so it gets no manifest. Your cards are never written to.

## Which Mac

Ingest has only been tested on macOS 27. macOS 14, 15 and 26 are untested, including the install steps above, though it says macOS 14 or later. It's built for Intel too, but has never been run on an Intel Mac. If you're on any of these, please say so when you report anything: the report carries your version, and your Mac is especially useful.

## Please don't rely on it yet

**Don't format a card on this beta's word alone without keeping another copy, until you're told otherwise.** Copy your cards the way you always have, or keep a second copy somewhere. If Ingest says Safe and you format anyway with no other copy, that's more trust than it has earned so far.

Clips aren't played. It proves the bytes match, and a clip that was already broken in camera will match perfectly. Open a few clips, as you normally would.

If a card or the drive comes out, the proof ends. Put the card back in and it reads everything again before it can say Safe, which takes about as long as reading the card once. That's on purpose, not a fault. If the drive is pulled during a copy, or the app crashes, nothing is lost. Plug it back in, or open the app again. Ingest checks what's already there by reading it, you carry on the copy for whatever's left, and it goes to Safe. If the drive really did lose something, Ingest won't say Safe: it names the file that doesn't match. Choose another folder and the whole card is copied there, or remove the bad copy and copy again. It goes to Safe once every file matches. A new folder leaves the old one alone, bad copy included. Safe says so at the time, but not on a later visit, so don't count on being reminded. If a card was filmed further after it was copied, it goes whole to a new folder beside the old one, because the camera rewrote its index. If Safe ever says a card is proved across two folders, keep both.

If the menu bar says **Have a look**, the warning is on the read-back line and it doesn't clear, the drive refused to say it had finished writing, a copy couldn't be read fresh from the disk, or part of Ingest's own record on the drive can't be read. Check the footage plays, or copy the card to another drive. If it says empty folders aren't on the drive, every file is there: another tool copied the card and left them out, and some cameras need them. Press **Add 4 Folders** on the drive line, or **Add Folder** for one, and it goes to Safe. It adds only those folders. A hold on the clips, such as a missing RED part, comes from the card, so another drive won't clear that one.

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
