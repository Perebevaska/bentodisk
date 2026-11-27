# BentoDisk

**English** · [Русский](README.ru.md)

**Download LLMs and other local AI models on macOS.**

BentoDisk searches Hugging Face, ModelScope, LM Studio, and Ollama Library from one window. Compare model variants, see which files are already on your Mac or external drives, and download the rest to the drive you choose.

[**Download for macOS**](https://github.com/Perebevaska/bentodisk/releases) · macOS 14+ · Apple Silicon and Intel

![Model browser showing Qwen variants, their sizes, and which ones are downloaded or queued on each drive.](docs/screenshots/browser-en.png)

## From search to disk

1. **Find a model.** Search across catalogs, pick one source, or paste a model URL. Browse popular and trending models where the source provides rankings.
2. **Choose the files.** Compare formats, quantizations, and sizes. Check which variants are already downloaded, whether a vision projector is available, and how much free space is on the destination drive.
3. **Choose where to store it.** Download directly to an internal or external drive, or save the model to Favorites with a planned destination. BentoDisk groups model folders by purpose.
4. **Manage the queue.** Add several models while a transfer is running. Pause and resume transfers, and reuse matching files after BentoDisk verifies them.

![Downloads showing one paused model with a Resume button and two models waiting in the queue.](docs/screenshots/queue-en.png)

The screenshots and demo use sample storage and queue data.

## Model catalogs and formats

| Catalog | What BentoDisk downloads |
| --- | --- |
| Hugging Face | Files from the selected repository revision, including GGUF variants and MLX or Safetensors bundles |
| ModelScope | Files from the selected model repository |
| LM Studio | Model files from the Hugging Face repositories linked by the LM Studio catalog |
| Ollama Library | Files for tags that provide local model weights |

BentoDisk can also find models in the library folders configured in LM Studio and Strata. Alongside LLMs for chat and coding, the browser covers models for embeddings, vision, image generation, audio, and video. Use a compatible runtime to run the downloaded models.

## Install

Open the DMG and drag **BentoDisk** into **Applications**. Python is included. Preview builds use an ad hoc signature. If macOS asks you to confirm the first launch, follow [Apple’s instructions](https://support.apple.com/en-us/102445).

<details>
<summary>Watch the 20-second demo</summary>

![BentoDisk searches for Qwen, compares variants, and opens the download details.](docs/bentodisk-demo.gif)

</details>

## Build from source

On a Mac with Xcode Command Line Tools, run the following command. It downloads the pinned Sparkle and CPython dependencies, then builds and verifies a universal DMG in `dist/`.

```sh
bash packaging/build-dmg.sh
```

To run the offline tests:

```sh
/usr/bin/python3 -B -m unittest discover -s tests
```

## Feedback

Tell us which catalog, model variant, or storage layout BentoDisk missed. Include your macOS version and the model repository, and remove personal paths from screenshots. [Open an issue](https://github.com/Perebevaska/bentodisk/issues/new).

## License

BentoDisk is licensed under the [MIT License](LICENSE). Bundled third-party components retain their own licenses.
