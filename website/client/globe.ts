// The board page's globe: where opted-in members are, by country, from the
// API's GET /globe. Bundled by `npm run build` into public/leaderboard/globe.js.
// Every value from the server is written with textContent, never as HTML.

import * as THREE from "three/webgpu";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { feature } from "topojson-client";
import { geoCentroid, geoEquirectangular, geoPath, type GeoPermissibleObjects } from "d3-geo";
import countries from "i18n-iso-countries";
import world from "world-atlas/countries-110m.json";

interface CountryTotal {
  country: string;
  members: number;
  tokens: number;
}

interface Placed extends CountryTotal {
  centre: [number, number];
}

const R = 1;
// No mint: it would vanish on green land.
const CANDY = [0xFFD84D, 0xFFB3C7, 0xA9D8FF, 0xC9B8FF, 0xFFC98A, 0xFF8A8A];
const names = new Intl.DisplayNames(["en"], { type: "region" });

const $ = (id: string) => document.getElementById(id);
const fmt = (n: number) => n >= 1e9 ? (n / 1e9).toFixed(1) + "B" : n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : String(n);
const flag = (code: string) => String.fromCodePoint(...[...code].map((c) => 0x1F1E6 + c.charCodeAt(0) - 65));
const nameOf = (code: string) => names.of(code) ?? code;

function el(tag: string, props: Record<string, string> = {}, ...kids: (Node | string)[]): HTMLElement {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "text") node.textContent = value;
    else if (key === "style") node.style.cssText = value;
    else node.setAttribute(key, value);
  }
  node.append(...kids);
  return node;
}

function toVec(lon: number, lat: number, r = R): THREE.Vector3 {
  const phi = (90 - lat) * Math.PI / 180, theta = (lon + 180) * Math.PI / 180;
  return new THREE.Vector3(-r * Math.sin(phi) * Math.cos(theta), r * Math.cos(phi), r * Math.sin(phi) * Math.sin(theta));
}

/** The flat Earth map: sky ocean, green land, ink coasts. */
function paintEarth(size: number): HTMLCanvasElement {
  const canvas = Object.assign(document.createElement("canvas"), { width: size, height: size / 2 });
  const ctx = canvas.getContext("2d")!;
  const topo = world as unknown as Parameters<typeof feature>[0];
  const land = feature(topo, (world as any).objects.land) as unknown as GeoPermissibleObjects;
  const path = geoPath(geoEquirectangular().scale(size / (2 * Math.PI)).translate([size / 2, size / 4]), ctx);
  ctx.fillStyle = "#DDEFFF"; ctx.fillRect(0, 0, size, size / 2);
  ctx.beginPath(); path(land);
  ctx.fillStyle = "#4CC38A"; ctx.fill();
  ctx.lineWidth = size / 1400; ctx.strokeStyle = "#1E1B2E"; ctx.lineJoin = "round"; ctx.stroke();
  return canvas;
}

/** Each country's centre on the map, by its ISO 3166 two-letter code. */
function centres(): Map<string, [number, number]> {
  const topo = world as unknown as Parameters<typeof feature>[0];
  const shapes = feature(topo, (world as any).objects.countries) as unknown as { features: (GeoPermissibleObjects & { id?: string })[] };
  const byNumeric = new Map(shapes.features.map((f) => [Number(f.id), geoCentroid(f) as [number, number]]));
  const result = new Map<string, [number, number]>();
  for (const code of Object.keys(countries.getAlpha2Codes())) {
    const numeric = countries.alpha2ToNumeric(code);
    const centre = numeric === undefined ? undefined : byNumeric.get(Number(numeric));
    if (centre) result.set(code, centre);
  }
  return result;
}

async function start(): Promise<void> {
  const host = $("globe");
  if (!host) return;
  const tip = $("globe-tip")!;
  const loading = $("globe-loading");
  let metric: "members" | "tokens" = "members";

  const renderer = new THREE.WebGPURenderer({ antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(2, devicePixelRatio));
  host.append(renderer.domElement);
  await renderer.init();
  const backend = $("globe-backend");
  if (backend) backend.textContent = (renderer.backend as { isWebGPUBackend?: boolean }).isWebGPUBackend ? "WebGPU" : "WebGL 2";

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
  camera.position.set(0, 0.6, 3.4);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true; controls.enablePan = false; controls.minDistance = 2; controls.maxDistance = 5;
  controls.autoRotate = true; controls.autoRotateSpeed = 0.6;

  scene.add(new THREE.Mesh(new THREE.SphereGeometry(R * 1.035, 64, 64), new THREE.MeshBasicMaterial({ color: 0x1E1B2E, side: THREE.BackSide })));
  const small = Math.min(innerWidth, innerHeight) < 700;
  const map = new THREE.CanvasTexture(paintEarth(small ? 2048 : 4096));
  map.colorSpace = THREE.SRGBColorSpace;
  map.anisotropy = renderer.getMaxAnisotropy();
  scene.add(new THREE.Mesh(new THREE.SphereGeometry(R, 96, 96), new THREE.MeshBasicMaterial({ map })));

  const grid = new THREE.Group();
  const gridMat = new THREE.LineBasicMaterial({ color: 0x3A7BD5, transparent: true, opacity: 0.16 });
  for (let lat = -60; lat <= 60; lat += 30) {
    const pts: THREE.Vector3[] = []; for (let lon = -180; lon <= 180; lon += 4) pts.push(toVec(lon, lat, R * 1.001));
    grid.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gridMat));
  }
  for (let lon = -180; lon < 180; lon += 30) {
    const pts: THREE.Vector3[] = []; for (let lat = -90; lat <= 90; lat += 4) pts.push(toVec(lon, lat, R * 1.001));
    grid.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gridMat));
  }
  scene.add(grid);

  const markers = new THREE.Group();
  scene.add(markers);
  const where = centres();
  let placed: Placed[] = [];

  function draw(): void {
    markers.clear();
    const shown = [...placed].sort((a, b) => b[metric] - a[metric]);
    const max = Math.max(1, ...shown.map((c) => c[metric]));
    shown.forEach((c, i) => {
      const h = 0.04 + 0.26 * (c[metric] / max);
      const color = CANDY[i % CANDY.length];
      const g = new THREE.Group();
      const parts: [THREE.BufferGeometry, number, THREE.Side, number][] = [
        [new THREE.CylinderGeometry(0.018, 0.018, h, 12), color, THREE.FrontSide, h / 2],
        [new THREE.CylinderGeometry(0.026, 0.026, h + 0.012, 12), 0x1E1B2E, THREE.BackSide, h / 2],
        [new THREE.SphereGeometry(0.034, 16, 16), color, THREE.FrontSide, h],
        [new THREE.SphereGeometry(0.044, 16, 16), 0x1E1B2E, THREE.BackSide, h],
      ];
      for (const [geometry, partColor, side, y] of parts) {
        const mesh = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({ color: partColor, side }));
        mesh.position.y = y; g.add(mesh);
      }
      const base = toVec(c.centre[0], c.centre[1], R);
      g.position.copy(base);
      g.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), base.clone().normalize());
      g.userData = c;
      markers.add(g);
    });
    const list = $("globe-list");
    list?.replaceChildren(...shown.slice(0, 8).map((c) => el("li", {},
      el("span", { class: "fill", style: `width:${(c[metric] / max) * 100}%` }),
      el("span", { text: flag(c.country) }),
      el("span", { text: nameOf(c.country) }),
      el("span", { class: "num", text: metric === "members" ? String(c.members) : fmt(c.tokens) }))));
    const title = $("globe-list-title");
    if (title) title.textContent = `Top countries · ${metric}`;
  }

  document.querySelectorAll<HTMLButtonElement>("[data-globe-metric]").forEach((button) => button.addEventListener("click", () => {
    metric = button.dataset.globeMetric === "tokens" ? "tokens" : "members";
    document.querySelectorAll("[data-globe-metric]").forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
    draw();
  }));

  const ray = new THREE.Raycaster(), pointer = new THREE.Vector2();
  renderer.domElement.addEventListener("pointermove", (event) => {
    const box = renderer.domElement.getBoundingClientRect();
    pointer.set(((event.clientX - box.left) / box.width) * 2 - 1, -((event.clientY - box.top) / box.height) * 2 + 1);
    ray.setFromCamera(pointer, camera);
    const hit = ray.intersectObjects(markers.children, true)[0];
    if (hit) {
      let group: THREE.Object3D = hit.object;
      while (group.parent !== markers) group = group.parent!;
      const c = group.userData as Placed;
      tip.replaceChildren(el("b", { text: `${flag(c.country)} ${nameOf(c.country)}` }), el("br"),
        `${c.members} members · ${fmt(c.tokens)} tokens · 30 days`);
      tip.style.left = `${event.clientX - box.left}px`; tip.style.top = `${event.clientY - box.top}px`; tip.style.opacity = "1";
      controls.autoRotate = false;
    } else { tip.style.opacity = "0"; controls.autoRotate = true; }
  });
  renderer.domElement.addEventListener("pointerleave", () => { tip.style.opacity = "0"; controls.autoRotate = true; });

  const resize = () => {
    const w = host.clientWidth, h = host.clientHeight;
    renderer.setSize(w, h, false);
    renderer.domElement.style.width = `${w}px`; renderer.domElement.style.height = `${h}px`;
    camera.aspect = w / h; camera.updateProjectionMatrix();
  };
  new ResizeObserver(resize).observe(host); resize();
  renderer.setAnimationLoop(() => { controls.update(); renderer.render(scene, camera); });

  try {
    const response = await fetch("https://claudebar-api.tddworks.com/globe?period=30d");
    if (!response.ok) throw new Error(String(response.status));
    const body = (await response.json()) as { countries: CountryTotal[]; hiddenCountries: number };
    placed = body.countries.flatMap((c) => {
      const centre = where.get(c.country);
      return centre ? [{ ...c, centre }] : [];
    });
    const count = $("globe-count");
    if (count) count.textContent = String(placed.length);
    const hidden = $("globe-hidden");
    if (hidden) hidden.textContent = String(body.hiddenCountries);
    loading?.remove();
    if (placed.length === 0) {
      $("globe-empty")?.removeAttribute("hidden");
    }
    draw();
  } catch {
    if (loading) loading.textContent = "The globe can't be reached right now.";
  }
}

start().catch(() => {
  const loading = $("globe-loading");
  if (loading) loading.textContent = "This browser can't draw the globe.";
});
