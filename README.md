# MacroDaddy
automated or on-demand FFXI macro backups

Tired of losing recent macro changes due to file corruption because you forgot to back them up manually and SE doesn't do a good job of doing that regularly?

MacroDaddy looks in your FFXI folder  to back up your macros (C:\Program Files (x86)\PlayOnline\SquareEnix\FINAL FANTASY XI\USER\) 
----edit this in the lua if you have it installed in a non-standard location.

Place macrodaddy folder into addons folder in your Windower directory
then //lua l macrodaddy in FFXI with windower or add to your init.txt

Windower\addons\MacroDaddy\
>MacroDaddy.lua
>backups\
>data\settings.lua

Data folder> Settings.xml holds the variables for path, etc. 
Can be manually edited, or you can change the path in game with    //md path "C:\your\folder\path\here"  

//md backup
//md status
//md help
//md login on|off
//md logout on|off
//md jobchange on|off
//md zonechange on|off
//md all on|off
//md path
//md path "folder"
**make sure you include the quotes, especially is there are spaces in any folder names in the path**


**warning if you set this to backup on zone, it will eat up space pretty quickly if you don't clear out the folder fairly regularly, .5-2Mb every time you zone adds up really quickly**

