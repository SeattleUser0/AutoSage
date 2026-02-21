import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";

const SUPPORTED_EXTENSIONS = new Set(["glb", "gltf", "obj", "stl"]);

function extensionOf(path) {
  const idx = path.lastIndexOf(".");
  return idx >= 0 ? path.slice(idx + 1).toLowerCase() : "";
}

function isRenderableAsset(path) {
  return SUPPORTED_EXTENSIONS.has(extensionOf(path));
}

export function findBestRenderableAsset(manifest) {
  if (!manifest || typeof manifest !== "object") {
    return null;
  }

  const rawAssets = manifest.assets;
  const assets = [];
  if (Array.isArray(rawAssets)) {
    for (const item of rawAssets) {
      if (typeof item === "string") {
        assets.push(item);
      }
    }
  } else if (rawAssets && typeof rawAssets === "object") {
    for (const key of Object.keys(rawAssets)) {
      const value = rawAssets[key];
      if (typeof value === "string") {
        assets.push(value);
      } else if (value && typeof value === "object" && typeof value.path === "string") {
        assets.push(value.path);
      }
    }
  }

  const preferredOrder = ["glb", "gltf", "obj", "stl"];
  for (const ext of preferredOrder) {
    const found = assets.find((item) => extensionOf(item) === ext);
    if (found) {
      return found;
    }
  }
  return assets.find(isRenderableAsset) ?? null;
}

function clearGroup(group) {
  while (group.children.length > 0) {
    const child = group.children.pop();
    if (child.geometry) {
      child.geometry.dispose();
    }
    if (child.material) {
      if (Array.isArray(child.material)) {
        child.material.forEach((entry) => entry.dispose());
      } else {
        child.material.dispose();
      }
    }
    group.remove(child);
  }
}

function frameObject(camera, controls, targetObject) {
  const box = new THREE.Box3().setFromObject(targetObject);
  if (!box.isEmpty()) {
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const radius = Math.max(size.x, size.y, size.z) * 0.6 || 1.0;

    camera.position.set(center.x + radius * 1.8, center.y + radius * 1.3, center.z + radius * 1.8);
    camera.near = Math.max(radius / 1000, 0.001);
    camera.far = Math.max(radius * 1000, 100);
    camera.updateProjectionMatrix();

    controls.target.copy(center);
    controls.update();
  }
}

export class GeometryViewport {
  constructor(container) {
    this.container = container;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color("#f8f4ee");

    this.camera = new THREE.PerspectiveCamera(45, 1, 0.01, 5000);
    this.camera.position.set(3, 2, 3);

    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;

    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;

    this.root = new THREE.Group();
    this.scene.add(this.root);

    const hemi = new THREE.HemisphereLight(0xfff0d8, 0x334433, 1.05);
    const key = new THREE.DirectionalLight(0xffffff, 1.25);
    key.position.set(4, 8, 5);
    this.scene.add(hemi, key);

    const grid = new THREE.GridHelper(10, 20, 0x8f8f8f, 0xc8c8c8);
    grid.position.y = -1.2;
    this.scene.add(grid);

    this.statusEl = document.createElement("div");
    this.statusEl.className = "viewport-status";
    this.statusEl.textContent = "No renderable asset yet";

    container.innerHTML = "";
    container.append(this.renderer.domElement, this.statusEl);

    this.onResize = this.onResize.bind(this);
    window.addEventListener("resize", this.onResize);
    this.onResize();

    this.running = true;
    this.loop = this.loop.bind(this);
    this.loop();
  }

  dispose() {
    this.running = false;
    window.removeEventListener("resize", this.onResize);
    this.controls.dispose();
    clearGroup(this.root);
    this.renderer.dispose();
  }

  onResize() {
    const rect = this.container.getBoundingClientRect();
    const width = Math.max(Math.floor(rect.width), 200);
    const height = Math.max(Math.floor(rect.height), 200);

    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(width, height, false);
  }

  loop() {
    if (!this.running) {
      return;
    }
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
    requestAnimationFrame(this.loop);
  }

  async loadAsset(url, assetPath) {
    clearGroup(this.root);
    const ext = extensionOf(assetPath);

    this.statusEl.textContent = `Loading ${assetPath}...`;
    try {
      let object3d;
      if (ext === "glb" || ext === "gltf") {
        const loader = new GLTFLoader();
        const gltf = await loader.loadAsync(url);
        object3d = gltf.scene;
      } else if (ext === "obj") {
        const loader = new OBJLoader();
        object3d = await loader.loadAsync(url);
      } else if (ext === "stl") {
        const loader = new STLLoader();
        const geometry = await loader.loadAsync(url);
        const material = new THREE.MeshStandardMaterial({
          color: "#d26d2d",
          metalness: 0.15,
          roughness: 0.55,
        });
        object3d = new THREE.Mesh(geometry, material);
      } else {
        this.statusEl.textContent = `Unsupported 3D format: .${ext}`;
        return;
      }

      this.root.add(object3d);
      frameObject(this.camera, this.controls, object3d);
      this.statusEl.textContent = assetPath;
    } catch (error) {
      this.statusEl.textContent = `Failed to load ${assetPath}: ${error.message}`;
    }
  }
}

export function isImageAsset(path) {
  const ext = extensionOf(path);
  return ext === "png" || ext === "jpg" || ext === "jpeg";
}

export function flattenManifestAssets(manifest) {
  if (!manifest || typeof manifest !== "object") {
    return [];
  }

  const rawAssets = manifest.assets;
  if (Array.isArray(rawAssets)) {
    return rawAssets.filter((entry) => typeof entry === "string");
  }

  if (rawAssets && typeof rawAssets === "object") {
    const output = [];
    for (const [key, value] of Object.entries(rawAssets)) {
      if (typeof value === "string") {
        output.push(value);
      } else if (value && typeof value === "object") {
        const path = typeof value.path === "string" ? value.path : null;
        if (path) {
          output.push(path);
        } else {
          output.push(key);
        }
      }
    }
    return output;
  }

  return [];
}
