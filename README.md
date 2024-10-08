# cis_libs - Cisoko Library System & Framework Bridge

## Overview

cis_libs is a comprehensive library system and framework bridge designed for FiveM resources. It provides a unified interface for common FiveM development tasks, supports multiple frameworks, and includes various utility functions to streamline resource development.

## Features

- **Framework Compatibility**: Supports ESX, ESX Legacy, QBCore, QBox, and custom frameworks.
- **Database Integration**: Works with various database systems including oxmysql, mysql-async, ghmattimysql, and MongoDB.
- **Inventory System Support**: Compatible with ox_inventory, qb-inventory, qs-inventory, and more.
- **Door Lock System**: Flexible and easy-to-use door management system.
- **Target System**: Integrates with popular targeting systems like ox_target and qb-target.
- **Logging System**: Comprehensive logging with console and Discord integration.
- **Vehicle and Weapon Utilities**: Helper functions for vehicle and weapon management.
- **PolyZone Integration**: Supports both PolyZone and ox_lib for zone management.

## Installation

1. Clone this repository into your FiveM resources folder.
2. Add `ensure cis_libs` to your server.cfg file.
3. Configure the `configs/master_config.lua` file to match your server setup.

## Configuration

Edit the following configuration files to customize cis_libs for your server:

- `configs/master_config.lua`: Main configuration file
- `configs/discordLogs_config.lua`: Discord logging settings
- `configs/security_config.lua`: Security settings and event prefixes

## Usage

### Client-side

```lua
local Framework = exports['cis_libs']:GetFramework()

-- Example: Show a notification
Framework.ShowNotification("Hello, world!")

-- Example: Check if player has an item
local hasItem = Framework.HasItem("water")
```

### Server-side

```lua
local Framework = exports['cis_libs']:GetFramework()

-- Example: Get all players
local players = Framework.GetPlayers()

-- Example: Give money to a player
Framework.GiveMoney(playerId, 1000, "cash")
```

## Documentation

For detailed documentation on all available functions and features, please visit our [official documentation](https://docs.cisoko.net).

## Support

For support, please join our [Discord server](https://discord.gg/cisoko).

## License

This project is licensed under a custom license. Please see the [LICENSE.md](LICENSE.md) file for details.

## Credits

Developed by Cisoko. Special thanks to the FiveM community for inspiration and support.

---

**Note: Alpha Version**

This is currently an alpha version of cis_libs. We are actively working on expanding and improving the library system. In the coming months, we plan to update and enhance cis_libs to become the most comprehensive library system available for FiveM development. Stay tuned for regular updates and new features!

