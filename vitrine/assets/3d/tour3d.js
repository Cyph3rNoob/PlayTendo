// Section « PlayTendo en 3D » de la vitrine : le vrai iPhone (modèle CC BY de Pro Animator) tourne et change d'écran
// pendant qu'on fait défiler la section. Three.js (MIT) n'est chargé que quand la section approche de l'écran, et
// l'image ne se calcule que pendant qu'elle est visible. Sans WebGL : l'image fixe de la section reste affichée.
// Écrans : captures de l'app en français ou en anglais, selon la langue choisie sur la page.

const section = document.getElementById("en-3d");
const canvas = section && section.querySelector(".tour-canvas");
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

function webglOK() {
  try { const c = document.createElement("canvas"); return !!(c.getContext("webgl2") || c.getContext("webgl")); }
  catch (e) { return false; }
}

if (section && canvas && webglOK()) {
  const proche = new IntersectionObserver(entries => {
    if (entries.some(e => e.isIntersecting)) { proche.disconnect(); demarrer(); }
  }, { rootMargin: "800px 0px" });
  proche.observe(section);
}

async function demarrer() {
  const THREE = await import("three");
  const { GLTFLoader } = await import("three/addons/loaders/GLTFLoader.js");
  const { DRACOLoader } = await import("three/addons/loaders/DRACOLoader.js");
  const { RoomEnvironment } = await import("three/addons/environments/RoomEnvironment.js");

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setClearColor(0x000000, 0);
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  const scene = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.55;
  const camera = new THREE.PerspectiveCamera(30, 1, 0.01, 10);
  camera.position.set(0, 0, 0.5);
  // Une lumière blanche, et deux néons (cyan à gauche, magenta à droite) qui dessinent les tranches.
  const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(0.4, 0.6, 1); scene.add(key);
  const rimC = new THREE.PointLight(0x00f0ff, 1.6, 0, 0); rimC.position.set(-0.35, 0.1, -0.15); scene.add(rimC);
  const rimM = new THREE.PointLight(0xff2bd6, 1.6, 0, 0); rimM.position.set(0.35, -0.05, -0.15); scene.add(rimM);

  // ---------- écrans (0 = démarrage, 1-5 = captures de l'app dans la langue de la page) ----------
  const loader = new THREE.TextureLoader();
  const cache = {};
  function tex(url) {
    if (!cache[url]) {
      const t = loader.load(url);
      t.colorSpace = THREE.SRGBColorSpace; t.flipY = false; t.anisotropy = 8;
      cache[url] = t;
    }
    return cache[url];
  }
  const langue = () => (document.documentElement.getAttribute("lang") === "en" ? "en" : "fr");
  const ecran = i => tex(i === 0 ? "assets/3d/ecrans/demarrage.jpg" : `assets/3d/ecrans/${langue()}/${i}.jpg`);
  const ecranMat = new THREE.ShaderMaterial({
    uniforms: { tA: { value: ecran(0) }, tB: { value: ecran(1) }, f: { value: 0 } },
    vertexShader: "varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
    fragmentShader: `uniform sampler2D tA, tB; uniform float f; varying vec2 vUv;
      void main() { gl_FragColor = vec4(mix(texture2D(tA, vUv).rgb, texture2D(tB, vUv).rgb, f), 1.0);
        #include <colorspace_fragment>
      }`,
    toneMapped: false,
  });

  // ---------- l'iPhone ----------
  const pivot = new THREE.Group(); scene.add(pivot);
  const draco = new DRACOLoader();
  draco.setDecoderPath("assets/3d/lib/draco/");
  const gltf = await new GLTFLoader().setDRACOLoader(draco).loadAsync("assets/3d/iphone.glb");
  gltf.scene.traverse(o => { if (o.isMesh && o.material && o.material.name === "ecran") o.material = ecranMat; });
  pivot.add(gltf.scene);

  // Positions clés, une par étape : x en part de la largeur visible (le téléphone à l'opposé du texte), angles en degrés.
  const CLES = [
    { x: 0.2, ry: -20, rx: 6, rz: 2, tex: 0 },
    { x: -0.22, ry: 24, rx: 4, rz: -3, tex: 1 },
    { x: 0.22, ry: -24, rx: 4, rz: 3, tex: 2 },
    { x: -0.22, ry: 20, rx: -4, rz: -2, tex: 3 },
    { x: 0.22, ry: -22, rx: 4, rz: 2, tex: 4 },
    { x: -0.22, ry: 24 + 360, rx: 4, rz: -3, tex: 5 },   // la dernière étape arrive par un tour complet
  ];
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
  const rad = THREE.MathUtils.degToRad;

  function poser(p, temps, debut) {
    const i = Math.max(0, Math.min(CLES.length - 2, Math.floor(p)));
    const t = Math.max(0, Math.min(1, p - i));
    const a = CLES[i], b = CLES[i + 1], e = smooth(0.12, 0.88, t);
    const portrait = camera.aspect < 1;
    const visH = 2 * Math.tan(rad(camera.fov / 2)) * camera.position.z, visW = visH * camera.aspect;
    // Ordinateur : le téléphone occupe ~68 % de la hauteur, à côté du texte ; téléphone (portrait) : en haut, le texte dessous.
    const s = portrait ? Math.min(visH * 0.5 / 0.163, visW * 0.6 / 0.078) : visH * 0.66 / 0.163;
    const flotte = reduce ? 0 : Math.sin(temps * 1.1) * 0.004;
    pivot.position.set(portrait ? 0 : lerp(a.x, b.x, e) * visW, (portrait ? visH * 0.14 : 0) + flotte, 0);
    // Arrivée dans la section : le téléphone se retourne vers nous (de dos au départ).
    const arrivee = reduce ? 0 : (1 - smooth(-0.9, 0, debut)) * -200;
    pivot.rotation.set(rad(lerp(a.rx, b.rx, e)), rad(lerp(a.ry, b.ry, e) + arrivee), rad(lerp(a.rz, b.rz, e)));
    pivot.scale.setScalar(s);
    ecranMat.uniforms.tA.value = ecran(a.tex); ecranMat.uniforms.tB.value = ecran(b.tex);
    ecranMat.uniforms.f.value = smooth(0.38, 0.62, t);
    rimC.intensity = 1.4 + 0.6 * Math.sin(p * 2.1); rimM.intensity = 1.4 + 0.6 * Math.cos(p * 1.7);
  }

  function taille() {
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  taille();
  addEventListener("resize", taille);

  // Calcul de l'image seulement quand la section est à l'écran.
  let visible = false;
  new IntersectionObserver(entries => { visible = entries.some(e => e.isIntersecting); }).observe(section);
  const etapes = section.querySelectorAll(".tour-step").length;
  let pLisse = null;
  renderer.setAnimationLoop(ms => {
    if (!visible) return;
    const r = section.getBoundingClientRect();
    // p : 0 quand la section touche le haut de l'écran, puis une unité par étape.
    const brut = -r.top / innerHeight;
    const p = Math.max(0, Math.min(etapes - 1, brut));
    pLisse = pLisse === null ? p : pLisse + (p - pLisse) * 0.14;
    poser(pLisse, ms / 1000, brut);
    renderer.render(scene, camera);
  });
  section.classList.add("tour-pret");
}
