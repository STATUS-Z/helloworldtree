// Hello World Tree — QML adapter.
//
// QML is the fourth of the four non-web languages (Rust + Lua + QML + Perl), and its job is the shell:
// a declarative UI over the Lua scripting surface, running natively rather than in a browser.
//
// That makes this file structurally different from every other adapter. The others extract a skeleton
// from a source file. This one *is* the surface — the thing a person looks at when the vessel is open
// and there is no browser available.
//
// The scene graph here is deliberately minimal: nodes as positions, edges as lines. Not because a
// richer visualisation would be hard, but because the dead vessel has no data to make a rich one
// meaningful. Rendering structure honestly is the whole job at this stage.

import QtQuick
import QtQuick.Controls
import QtQuick.Shapes

Item {
    id: root

    // ── The vessel, as handed over by the host ────────────────────────────────
    // Lua owns the graph, Rust owns the process. QML receives plain data and draws it. No adapter
    // reaches into a model it does not own.

    property var nodes: []       // [{ id, kind, label, x, y }]
    property var edges: []       // [{ from, to }]
    property string digest: ""   // the compact readout, shown as the status line
    property string mode: "static"  // "static" | "live"

    // ── Palette ──────────────────────────────────────────────────────────────
    // Dioxazine void, magenta hum, gold-to-white type. The same values the web surface uses, so the
    // two shells are recognisably one thing.

    readonly property color voidColor:     "#030208"
    readonly property color dioxColor:     "#0b0414"
    readonly property color humColor:      "#e5007e"
    readonly property color humHotColor:   "#ff2d9b"
    readonly property color indigoColor:   "#2e3bff"
    readonly property color goldColor:     "#ffd400"
    readonly property color typeHi:        "#ffffff"

    // ── The drawing surface ──────────────────────────────────────────────────
    // Canvas rather than Shape per node: one draw call for the whole graph rather than one per element.
    // At 200 nodes the difference is the gap between smooth and not.

    Canvas {
        id: canvas
        anchors.fill: parent
        anchors.margins: 24
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();

            // Ground. Two radial lobes, not one centred gradient — a centred gradient reads as a
            // vignette, which is a camera artefact rather than a property of the space.
            const g1 = ctx.createRadialGradient(width * 0.25, height * 0.15, 0,
                                                width * 0.25, height * 0.15, width * 0.8);
            g1.addColorStop(0, "#1a0a28");
            g1.addColorStop(0.55, "#0b0414");
            g1.addColorStop(1, "#030208");
            ctx.fillStyle = g1;
            ctx.fillRect(0, 0, width, height);

            // Edges first, so nodes sit on top of them.
            ctx.strokeStyle = root.indigoColor;
            ctx.globalAlpha = 0.35;
            ctx.lineWidth = 1;

            const byId = {};
            for (const n of root.nodes) {
                byId[n.id] = n;
            }

            for (const e of root.edges) {
                const a = byId[e.from];
                const b = byId[e.to];
                if (!a || !b) continue;
                ctx.beginPath();
                ctx.moveTo(a.x * width, a.y * height);
                ctx.lineTo(b.x * width, b.y * height);
                ctx.stroke();
            }

            // Nodes. Radius by kind, because kind is the only property the dead vessel has.
            ctx.globalAlpha = 1;
            for (const n of root.nodes) {
                const r = n.kind === "file" ? 6 : n.kind === "import" ? 3.5 : 4.5;
                const x = n.x * width;
                const y = n.y * height;

                // Halo, so a node separates from the void without needing a stroke.
                const halo = ctx.createRadialGradient(x, y, 0, x, y, r * 4);
                halo.addColorStop(0, root.humHotColor);
                halo.addColorStop(1, "rgba(229,0,126,0)");
                ctx.fillStyle = halo;
                ctx.beginPath();
                ctx.arc(x, y, r * 4, 0, Math.PI * 2);
                ctx.fill();

                ctx.fillStyle = n.kind === "file" ? root.goldColor : root.typeHi;
                ctx.beginPath();
                ctx.arc(x, y, r, 0, Math.PI * 2);
                ctx.fill();
            }
        }

        Connections {
            target: root
            function onNodesChanged() { canvas.requestPaint() }
            function onEdgesChanged() { canvas.requestPaint() }
        }

        Component.onCompleted: requestPaint()
    }

    // ── Status line ──────────────────────────────────────────────────────────
    // The digest, because a person looking at a skeleton needs to know whether it is complete before
    // they need to know what is in it.

    Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 24
        width: statusText.implicitWidth + 24
        height: statusText.implicitHeight + 16
        color: Qt.rgba(0.02, 0.008, 0.05, 0.86)
        border.color: root.humColor
        border.width: 1
        radius: 2

        Text {
            id: statusText
            anchors.centerIn: parent
            text: root.digest.length ? root.digest : "vessel empty"
            color: root.goldColor
            font.family: "monospace"
            font.pixelSize: 11
            font.letterSpacing: 0.5
        }
    }

    // ── Mode indicator ───────────────────────────────────────────────────────
    // "static" is the honest default. A vessel with no data flow is not live, and saying so is what
    // keeps the shell from implying more than it has.

    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 24
        width: modeText.implicitWidth + 20
        height: modeText.implicitHeight + 12
        color: "transparent"
        border.color: root.mode === "live" ? root.humHotColor : root.indigoColor
        border.width: 1
        radius: 2

        Text {
            id: modeText
            anchors.centerIn: parent
            text: root.mode.toUpperCase()
            color: root.mode === "live" ? root.humHotColor : root.indigoColor
            font.family: "monospace"
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }
}
