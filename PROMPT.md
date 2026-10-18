# Copy-paste prompt

Open Claude Code (or another coding agent that can run commands on your Mac), paste this, and press Enter.

```text
I want to install Open Dictation on this Mac: a free app that types what I say, wherever my cursor is.

1. Clone https://github.com/kub-ski/open-dictation into ~/open-dictation (if the folder is already there, run `git pull` in it).
2. Read README.md in that folder so you know how it works.
3. Ask me these three questions, one at a time, and wait for each answer:
   a) What should the app be called? (default: OpenDictation)
   b) What language do I speak? (default: auto-detect; or a code like en, pl, de, es, fr)
   c) Which key do I hold to talk? (default: Fn; or right-option, right-command, right-control)
4. Run ./setup.sh with my answers, for example:
   ./setup.sh --name "MyName" --language en --hotkey fn --yes
   If it stops, read the message, fix the cause, and run it again. It is safe to repeat.
5. Then walk me through the macOS permission screens ONE AT A TIME, and wait for me to say "done" after each:
   - If my key is Fn: System Settings > Keyboard > "Press 🌐 key to" > Do Nothing.
   - Allow the Microphone when macOS asks.
   - System Settings > Privacy & Security > Accessibility: switch my app on.
   - System Settings > Privacy & Security > Input Monitoring: switch my app on.
   Tell me exactly where to click. Open each Settings page for me with the `open` command.
6. Quit and reopen the app once, open TextEdit, and ask me to hold my key and say a sentence. Confirm the text appeared.

Use plain words. I am not technical. Do not ask me to run commands: you run them. Do not change anything outside the steps above.
```

If you use another agent, change nothing: the same prompt works. Prefer to do it by hand? See [README.md](README.md).
