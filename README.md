this is a project for a tui to browse and alter the shard system. we essentially want a text editor
that executes ai commands and looks into the shards for guideance

the idea is that we open files and write inline in two different modes

one is ai mode where we send questions or tasks to a specific area of the file we rite to the ai
and then it returns back with answers and information.


the idea is that we dont really have files anymore, we have a living file between ai and humand
and we work on it at the same time

and ai can tell us whats the next thing is we need to work on

so the general idea for the tui is to create a editor where the curosr
is always on the center line, and if we switch files
we just get a 'code lens' zoom into the new file.

if we close the file, we jump back to the previous code lens.

so we are opening stacked 'contexts' and basically can follow a trail ow why we 
switched to a different file.


and we can just continue working and flowing


so the first todo would be to write an app that renders random characters on the screen
without any visual lags
