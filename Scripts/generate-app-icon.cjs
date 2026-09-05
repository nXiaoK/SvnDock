#!/usr/bin/env node

// Artwork-only tool; the app build uses the checked-in ICNS and needs no Node.
// Requires Node.js and sharp (install separately and set NODE_PATH if needed).
// Run from any directory: node Scripts/generate-app-icon.cjs
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const sharp = require('sharp');

const resources = path.resolve(__dirname, '../SvnDockApp/Resources');
const iconset = path.join(resources, 'SvnDock.iconset');

async function main() {
    const svg = await fs.readFile(path.join(resources, 'SvnDockIcon.svg'));
    // Render directly to RGBA. Thumbnail/Quick Look exports can flatten the
    // transparent SVG canvas to white even when the PNG has an alpha channel.
    const master = await sharp(svg).png().toBuffer();
    await verifyTransparency(master);
    await fs.writeFile(path.join(resources, 'SvnDockIcon.png'), master);
    await fs.mkdir(iconset, { recursive: true });

    for (const size of [16, 32, 128, 256, 512]) {
        for (const scale of [1, 2]) {
            const png = await sharp(master).resize(size * scale, size * scale).png().toBuffer();
            await verifyTransparency(png);
            const suffix = scale === 2 ? '@2x' : '';
            await fs.writeFile(path.join(iconset, `icon_${size}x${size}${suffix}.png`), png);
        }
    }
    execFileSync('/usr/bin/iconutil', [
        '--convert', 'icns', '--output', path.join(resources, 'SvnDock.icns'), iconset,
    ], { stdio: 'inherit' });
    console.log('Generated transparent PNG, all 10 iconset sizes, and SvnDock.icns.');
}

async function verifyTransparency(png) {
    const { data, info } = await sharp(png).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const { width, height, channels } = info;
    const alpha = (x, y) => data[(y * width + x) * channels + channels - 1];
    if ([[0, 0], [width - 1, 0], [0, height - 1], [width - 1, height - 1]]
        .some(([x, y]) => alpha(x, y) !== 0)
        || alpha(Math.floor(width / 2), Math.floor(height / 2)) !== 255) {
        throw new Error('Icon must have transparent corners and opaque artwork.');
    }
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
