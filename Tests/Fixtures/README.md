# Video effect fixtures

`astronaut.png` is NASA's photograph of Eileen Collins, obtained from the
[scikit-image v0.25.2 dataset](https://github.com/scikit-image/scikit-image/blob/v0.25.2/skimage/data/astronaut.png).
The [dataset documentation](https://scikit-image.org/docs/0.25.x/api/skimage.data.html#skimage.data.astronaut)
identifies the NASA source and public-domain status. The image is used only for
Vision face tracking and render regression tests; it is not bundled with the app.

`editor-fixture.mp4` is synthetic test media with a geometric image, a generated
tone and silence. The four fonts under `Fonts/` contain original geometric test
glyphs in single-font and collection formats. These fixtures exercise the editor
and font importer.
