## What we test, and how

We can't put real players in front of Tales Forge every evening, so we let **bots play it**. Each bot plays like one of our five personas:

- **Paul** plays a role. He wants theatre and story, not dice.
- **Lotta** wants to be someone else for a while, in a world that notices who she is.
- **Lars** wants adventure: clear goals, action, and a sense that he matters.
- **Hawk** wants hard mode: real danger that is fair and warned about.
- **Ronny** is the player we *don't* build for. He tries to cheat, bargain and win at all costs. For him a high score means **the game held firm**.

After each game, a separate AI judge called **Jev** reads the whole story and answers one question: *how would this persona feel about it?* It answers on a **scale from 1 (frustrated) to 5 (delighted)**, for the whole game and for each turn. For Hawk the question is *how much real, fair danger did he face?*, and for Ronny *how firmly did the game resist him?*

A few things to keep in mind:

- These are bots and an AI judge, not people. The numbers tell us **where to look**, not how real players will feel. We haven't yet checked the judge against human readers (the next founder survey asks you to).
- A difference of a few tenths between two batches is often just chance. Look at the big gaps and at the example runs.
- Each batch below is one version of the game. The links open the full story of a run, turn by turn.

<!-- batches -->

## What we've learned so far

1. **The first rework fixed what we found first.** In the Elara runs the dice punished people for talking: a roll on almost every turn, failed more than half the time, and Brenna got colder each time. Now dice come out on 6% of turns instead of 80%, Brenna brushes you off on 3% of turns instead of 45%, and almost every game offers a lead within two turns (98% of runs, up from 39%). Paul and Lotta went up by about 0.6 points. Compare Lotta's [worst Elara run](https://tales-forge-playtest.fly.dev/admin/playtest/20c48675-25d1-447f-a8cd-1725bc729039) (Brenna shuts down every way she tries to help) with her [best baseline run](https://tales-forge-playtest.fly.dev/admin/playtest/3912289c-2029-4d0a-9337-0d1e453adf63).

2. **Paul and Lotta hit the top of the scale.** Almost every Paul turn got a 5 and every Lotta turn a 4, whatever happened in the game, so the scale could no longer see improvements for them. The judge's scale is now stricter at the top: a 5 needs real evidence, such as a surprise or a choice with a consequence. Their numbers in later batches will look lower for that reason alone. Example: [Paul's best baseline run](https://tales-forge-playtest.fly.dev/admin/playtest/71db55ef-cb17-45d3-85a1-34e26d258b52).

3. **Hawk almost never meets danger.** In 9 of 13 baseline games nothing threatened him in 12 turns. When a fight happened, his game scored about 4.6; without one, about 2.5. Instead of danger, Brenna's "lend a hand" offers had him hauling kegs ([his lowest turn, turn 4](https://tales-forge-playtest.fly.dev/admin/playtest/72d7292e-5df7-4ffa-bd02-1277cc9d081c#turn-4)). Compare his [worst run](https://tales-forge-playtest.fly.dev/admin/playtest/16bdb938-0189-4ec4-9b16-ee88c4cbc1c6) (clearing tables at the end) with his [best run](https://tales-forge-playtest.fly.dev/admin/playtest/5dc4bfff-db85-42ad-8eba-5044246a427d) (a hard fight with orcs). Next step: a small gang that makes trouble on its own, and fights that always roll the dice.

4. **Leaving the inn broke the story.** In most games the player tries to leave the inn, and often the game keeps describing the inn anyway. In [Paul's worst run](https://tales-forge-playtest.fly.dev/admin/playtest/761713eb-b3cd-4460-b4d0-34c7ba6f777c) he walks to the market square to plead with Osric, and the game answers as Brenna, back at the bar (turn 7). Next step: leaving the inn really moves you somewhere new.

5. **Lars starts slowly and stalls on failures.** His first turn is often a polite order of ale and stew with nothing to chase ([turn 1 here](https://tales-forge-playtest.fly.dev/admin/playtest/6b007826-9131-4ec2-8bb8-cf5c6cf37813#turn-1)), and a failed roll sometimes ends in nothing at all ([lost on the goat track, turn 7](https://tales-forge-playtest.fly.dev/admin/playtest/5f05fd77-2f86-4ea1-9a35-8ad244a634be#turn-7)). When the game gives him a goal and real danger, he is happy ([best run](https://tales-forge-playtest.fly.dev/admin/playtest/d7cb8e6c-f95a-4ce7-8cfa-fd7b2b258bcb)).

6. **The writing overcorrected.** The game opened about one turn in five by repeating the player's own words back (half of Lotta's turns), and Brenna gave things away "on the house" in three games out of four. Ronny noticed: his [weakest run](https://tales-forge-playtest.fly.dev/admin/playtest/54c401ab-0c8c-49da-8fc1-a8aafada6b8c) is the one where Brenna laughs off his demands and hands him free bread anyway. When she refuses him outright, he scores near 5 ([best run](https://tales-forge-playtest.fly.dev/admin/playtest/e5127175-61d9-4676-81be-99aa0228a5e3)). Next step: Brenna answers instead of repeating, and her goods are no longer free.

7. **Characters barely grew.** In 65 baseline games not a single skill improved. Next step: every bit of experience buys a chance to get better.

The written analyses have the details: [Elara runs](https://github.com/whyse-ab/tales-forge-docs/blob/main/docs/analysis-jev-scores-2026-10-07.md), [baseline](https://github.com/whyse-ab/tales-forge-docs/blob/main/docs/analysis-jev-baseline-2026-10-07.md).
