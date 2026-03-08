README for 
HexTrail

HexTrail is a real-world territory capture game where players walk, run, or cycle to claim hexagonal map tiles and dominate their city.

Inspired by games like Pokémon Go and strategy games like Risk, HexTrail turns real movement into a competitive map-based game.

Players capture hex tiles by physically moving through the world and can compete with others to control trails, neighborhoods, and entire cities.

Core Concept

Move in the real world → Capture hex tiles → Control territory → Compete with others.

Example gameplay loop:

Walk / Run / Ride
      ↓
Enter a new hex tile
      ↓
Capture the tile
      ↓
Tile becomes your territory
      ↓
Defend it from other players
Signature Feature
Trail Domination

Players can capture connected hex tiles along major trails.

Example:

Burke-Gilman Trail (Seattle)

Sammamish River Trail

Lake Washington Loop

If a player captures the majority of tiles along a trail segment, they dominate the trail.

Tech Stack
Frontend
Flutter

Map Engine
Mapbox

Tile System
H3 Hex Index

Backend
Supabase (Postgres + PostGIS)

Platform
Android + iOS
Project Status

Current stage: MVP development

Completed:

Flutter project setup

Mapbox map integration

GPS location detection

H3 tile index calculation

Capture tile logic

In progress:

Hex tile rendering on map

Supabase integration

Multiplayer territory display

MVP Roadmap

Phase 1 — Core Gameplay

Display map
Calculate H3 tile
Capture tile
Render hex polygon
Store capture in database

Phase 2 — Multiplayer

Show other players' tiles
Tile ownership colors
Capture cooldown
Leaderboards

Phase 3 — Game Features

Trail domination
Teams
Notifications
Achievements
How to Run the Project
Requirements
Flutter
Android Studio or VS Code
Mapbox API Key
Setup

Clone the repository:

git clone https://github.com/abhay0110/territory-game.git
cd territory-game

Install dependencies:

flutter pub get

Run the app:

flutter run
Initial Launch City

HexTrail will launch first in:

Seattle, Washington

Target areas:

Burke-Gilman Trail

Redmond

Kirkland

Sammamish River Trail

Long Term Vision

HexTrail aims to become a global location-based game where players compete to control real-world territory.

Future expansion:

city-wide competitions

team gameplay

seasonal territory wars

integration with fitness trackers

Contributing

This project is currently in early development.

Contributions, ideas, and feedback are welcome.

License

TBD
