# ZoneRecipeWaypoints

A small addon for **World of Warcraft: Forever**. When you enter a zone, it sets
[TomTom](https://www.curseforge.com/wow/addons/tomtom) waypoints for the trainers and vendors
there that teach or sell recipes the current character still needs.

Recipe data comes from the **RecipeRadar** addon.

## Features

- Waypoint labels name the NPC, the professions, and up to 6 recipes to pick up, with their
  skill requirements.
- Skips recipes the character already knows, already carries the teaching item for (bags or
  bank), or cannot use because of class or specialisation.
- Includes "learnable soon" recipes only when **Learnable Soon** is ticked in RecipeRadar.
- Refreshes when you learn a recipe.

## Requirements

- RecipeRadar (required)
- TomTom (needed for the waypoints)

Open each profession window once on every character, so RecipeRadar can record the recipes it
already knows.

## Installation

Clone or copy this folder into `World of Warcraft/_forever_/Interface/AddOns/`, keeping the
folder name `ZoneRecipeWaypoints`.

## Commands

| Command | Effect |
|---|---|
| `/zrw` or `/zrw run` | Refresh the waypoints for the current zone |
| `/zrw on` / `/zrw off` | Enable, or disable and clear |
| `/zrw learnable` | Only recipes within your skill and level (default) |
| `/zrw all` | Ignore the skill and level limits |
| `/zrw max N` | Most waypoints per zone, 1 to 60 (default 12) |
| `/zrw quiet` | Toggle chat messages |
| `/zrw clear` | Remove the waypoints |
