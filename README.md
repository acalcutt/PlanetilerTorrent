# PlanetilerTorrent
a script to generate planetiler torrents. This is meant to be triggered on OpenStreetMap planet pbf torrent completion ( https://wiki.openstreetmap.org/wiki/Planet.osm#BitTorrent )

# Server Setup

1. Install qbittorent. I followerd this quide https://pimylifeup.com/ubuntu-qbittorrent/

2. Download the planetiler jar file ( https://github.com/onthegomap/planetiler ). The script expects 'planetiler_0.6.0.jar' to '/opt/planetiler'. Note that planetiler requires java 17+ installed, which I installed with 'apt install openjdk-17-jdk openjdk-17-jre'

3. create local paths used by the script

```
/opt/PlanetilerTorrent (script files in this repo)
/store/http/ (where all the rss and torrent files for users get put. I use this as the root of a apache virtual host site)
/store/planet/ (where qbittorent will download the planet pdb files)
/store/planetiler/ (where the planetiler files are generated by create_planetiler_torrent.sh)
/store/upload/ (a folder that qbittorent monitors for automatic import)
```

4.  Give the folders inside /store write permissions to the qbittorent group created when setting up qbittorent

5. In qbittorent, set up this script.
   - In (Options -> Download -> Run external program on torrent completion)
        add '/opt/PlanetilerTorrent/create_planetiler_torrent.sh %N %F %I' . This will run when torrent files finish, and pass on filename, path, and hash variables to the script.
   - In (Options -> Download -> Automatically add torrents from) 
        add '/store/upload' as a monitor foler and '/store/planetiler/' as save location. When a torrent is added to this '/store/upload' folder, it will automatically import into qbittorent. Since the file will already exist in '/store/planetiler/' the file will start seeding. The script places torrent files in this folder as they are created.

6. Set up OpenStreetMap planet pbf rss feed in qbittorent.
   - In the qbittorrent web ui, go to the 'RSS' tab and click 'New Subscription'
        add the osm rss feed ( https://planet.openstreetmap.org/pbf/planet-pbf-rss.xml ), click OK
   - Go back to the 'Transfers' tab and right click 'All' under 'CATEGORIES' in the left menu. Select 'Add Category'.
        add the category 'planet' and set the save folder to '/store/planet'
   - In (Options -> RSS -> RSS Torrent Auto Downloader -> Edit auto downloading rules)
        click the button to create a new rule. Set Category as 'planet'. Apply the rule to RSS feed you added earlier. Click Save

7. Optional
   - Create a firewal rule to allow TCP/UTP connections to the port listed on (Options -> Connection -> Listening port). my understanding is this is not neccesary, but will improe seeding.
   - Set up speed restricions in (Options -> Speed)
   - As an alternative to seeding by qbittorrent, you can also modify the mktorrent command in the create_planetiler_torrent.sh script to specify "web seeds" with the -w [url] flag. the files would need to be accessable by http at the url specified in the -w flag. This allows seeding without a torrent server. (I chose to seed through torrent for better bandwith control and cleanup option, but seeding by http like this is also an option)

Once this has set up, OpenStreet
        
