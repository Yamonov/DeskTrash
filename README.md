# DeskTrash
Bring back the Trash icon to the Mac desktop

Restores a movable old-style Trash icon to the desktop.
You can drag files, folders, and volumes onto it to move them to the Trash or unmount them, like in older versions of macOS.

You can also empty the Trash by right-clicking it.

Please prepare the icon and sound resources yourself. They are intentionally not included in this repository.

Create a folder named `DeskTrash/Resources`, and place the following image and sound files directly inside it using these exact filenames:

- `trashempty2@2x.png`
- `trashfull2@2x.png`
- `Dragtotrash.caf`
- `Emptytrash.caf`
- `eject.caf`

The app icon and menu bar icon image assets are also not included. Add your own files under:

- `DeskTrash/Assets.xcassets/AppIcon.appiconset/`
- `DeskTrash/Assets.xcassets/MenuIcon.imageset/`
