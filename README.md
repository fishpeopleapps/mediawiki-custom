# mediawiki-custom

# Custom MediaWiki Image

This repository contains the source files for building a custom MediaWiki container image.  
The image is designed to run on the Gravity Platform using the **External Image Pipeline** and will be published to Harbor for internal use.

---

## Purpose
- Provide a stable, secure MediaWiki image for our platform.  
- Maintain explicit control over included extensions, configuration, and dependencies.  
- Support Gravity’s external image ingestion pipeline without requiring Iron Bank.

---

## Usage with Gravity External Image Pipeline

### Prerequisites
1. Ensure this repository has a support ticket requesting setup of an External Image Pipeline.  
2. Confirm your project is authorized to import images from an allowed registry (`ghcr.io`).

### Running the Pipeline
1. Go to this repository in GitLab.  
2. Navigate to **Build > Pipelines > Run pipeline**.  
3. Select the branch you wish to run.  
4. Enter the required environment variables:  

- `IMAGE_URI`: Path and tag for Harbor (must not be blank or `latest`).  
- `IMAGE_NAME`: Full path to the external image (e.g., `ghcr.io/org/mediawiki-custom:1.0.0`).  
- `TEAM_NAME`: Your team name.  
- (Optional) `EXTERNAL_REGISTRY_USER`, `EXTERNAL_REGISTRY_TOKEN`, `EXTERNAL_REGISTRY_URL` — if required.  
- (Optional) `IMAGE_PATH_OVERRIDE` — use to customize storage path.

5. Click **Run pipeline**.  
If successful, the image will be pulled, scanned, and pushed into Harbor for internal use.

---

## Development
- Images are built locally first for validation and testing.  
- Once validated, images are tagged and published to **GitHub Container Registry (ghcr.io)**.  
- Gravity’s External Image Pipeline is then used to ingest the image into Harbor.  

---

## License
**UNLICENSED** – This repository is for internal use only.  
Do not distribute without prior authorization.
