# Spark Word in a Staffbase email

Staffbase Email won't run the game inside the message (no email client runs JavaScript);
the email carries a **link** and the game opens in the browser. Two ways to do it:

## A. Generic link — simplest, no CSV (good for internal, Turner & Townsend audiences)

Everyone gets the same link. Players are asked once for name, email and company before
they're ranked. The link can pre-fill the company so employees only type their name:

```
https://YOUR-SITE/index.html?ref=staffbase&company=Turner%20%26%20Townsend#spark-word
```

In the Staffbase designer, add at the bottom of the email:

1. **Image** element → upload `spark-word-banner@2x.png` (600 px display width) → link it to the URL above.
2. **Text** element →
   *Can you crack this issue's Spark Word? Five letters. Six guesses. See how you rank against the TMT industry.*
3. **Button** element → label **Play Issue 014 →** → link: the URL above.
4. **Text** element (small, grey) → *387 people played last issue. Can you make the Top 10?*

Streaks and rank still work: after the first claim the browser remembers the player, and
someone who plays from another device just enters the same email again (verified by a
one-time link).

## B. Personal links — one link per reader (streaks with zero typing)

1. In the admin dashboard: **Subscribers & links → CSV format: Staffbase custom data → Download CSV**.
   Columns: `identifier` (email), `firstName`, `lastName`, `company`, `gameUrl`.
2. In Staffbase Email, upload that CSV as **custom data / custom target group** for the send
   (the `identifier` column matches recipients by email).
3. Use the tags in the design: `{{firstName}}` in text, `{{gameUrl}}` as the **button link**.
   Send yourself a test first — if the button URL field doesn't accept a tag in your
   version, put the tag in a text link instead ("Play Issue 014 →" with link `{{gameUrl}}`),
   or fall back to option A.

## C. Pasting HTML

`spark-word-block.html` is an Outlook-safe table block with the same tags. Staffbase allows
pasting HTML through the Rich Text Editor but recommends native blocks; if the paste renders
oddly in Outlook, use option A.

## Every issue

Replace `014` and the "people played" figure (admin → Analytics) in the copy; export a fresh
CSV if you use personal links (tokens don't change, only the issue number in the URL).
