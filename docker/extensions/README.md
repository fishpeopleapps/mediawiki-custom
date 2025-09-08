# MediaWiki Extensions Configuration

This folder contains the configuration for installing MediaWiki extensions and skins
into the image, using a Canasta-style YAML file plus a small fetch script.

## Files

- **extensions.yaml**  
  Main list of extensions and skins.  
  - Supports `inherits:` to pull in the Canasta RecommendedRevisions for MW 1.43.  
  - Extensions/skins listed here override the inherited defaults.  
  - Each entry can pin a branch, tag, or commit.

- **scripts/extensions-fetch.sh**  
  Script that reads the YAML, clones the repos, and checks out the correct versions
  into `/var/www/html/extensions` and `/var/www/html/skins`.

## Example YAML

```yaml
inherits: https://raw.githubusercontent.com/CanastaWiki/RecommendedRevisions/18bdb18e0504ef9442e1bd0484497b34634b5515/1.43.yaml

extensions:
  - PageForms:
      repository: https://github.com/wikimedia/mediawiki-extensions-PageForms.git
      commit: 35099cf9fab298ceb5fbc51ed2c721eae2728406
  - CirrusSearch:
      repository: https://gerrit.wikimedia.org/r/mediawiki/extensions/CirrusSearch
      branch: REL1_43
      version: 8.0.0
  - Elastica:
      repository: https://gerrit.wikimedia.org/r/mediawiki/extensions/Elastica
      branch: REL1_43
      version: 6.2.0

skins:
  - Citizen:
      repository: https://github.com/StarCitizenTools/mediawiki-skins-Citizen
      branch: main
