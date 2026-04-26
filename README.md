## Update drupal modules 
This is vibe coded bash script to help ease the pain of updating drupal contrib modules and core

## what it does
- uses ddev by default to run composer (ddev composer)
- it uses `ddev composer outdated "drupal/*"` to find what needs to be updated
- it updates one by one
- it lets module dependencies update when needed
- core is skipped unless you pass `--allow-core`
- if core is allowed, it updates contrib modules first and core last
- updates the database `drush updb`
- exports any configuration changes `drush cex` 
- and commits with sensible message

## usage
- `./update-modules.sh` updates eligible contrib modules
- `./update-modules.sh token pathauto` updates only those packages
- `./update-modules.sh --allow-core` includes core, after modules
- `./update-modules.sh --allow-major` allows major upgrades
- `./update-modules.sh --dry-run` shows what would run


## Safety Checks 
- skips core updates unless `--allow-core` is used
- skips major upgrades unless `--allow-major` is used
- keeps core dependency updates for the core pass
- runs modules one at a time, with database updates and config export after each one
- skips drush and commit if composer does not change the package in the lock file
- prevents composer removing a module that was deprecated in a newer version while drupal still has it installed
- it will stop if there is composer error
