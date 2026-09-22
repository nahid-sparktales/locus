import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { InstancedMesh } from '@babylonjs/core/Meshes/instancedMesh.js';
import { VertexBuffer } from '@babylonjs/core/Buffers/buffer.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js';
import type { AssetContainer, InstantiatedEntries } from '@babylonjs/core/assetContainer.js';
import type { Scene } from '@babylonjs/core/scene.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import type { SceneryAssetType, Theme } from './theme.ts';
import { ZuneshaStride } from './grandLineCompanions.ts';
import { WaterfallFlow } from './waterfallFlow.ts';

export type SceneryPlacement = { parent: TransformNode; width: number; depth: number; height: number; floor: number; rotation?: number; footprintRadius?: number; animated?: boolean; interactionID?: 'laboon' };
type InstalledModel = { instance: InstantiatedEntries; pivot: TransformNode };

/** Installs embedded Meshy geometry inside the same footprints used by navigation. */
export class GrandLineModels {
  private placements = new Map<SceneryAssetType, SceneryPlacement[]>();
  private instances: InstalledModel[] = [];
  private installed = new Set<SceneryAssetType>();
  private waterfallFlows: WaterfallFlow[] = [];
  private elephantStrides: ZuneshaStride[] = [];
  private disposed = false;
  private scene: Scene;
  private shadow: ShadowGenerator;
  private theme: Theme;
  constructor(scene: Scene, shadow: ShadowGenerator, theme: Theme) { this.scene = scene; this.shadow = shadow; this.theme = theme; }

  has(type: SceneryAssetType): boolean { return Boolean(this.theme.assets[type]); }

  add(type: SceneryAssetType, placement: SceneryPlacement): void {
    if (this.disposed) return;
    const entries = this.placements.get(type) ?? [];
    entries.push(placement); this.placements.set(type, entries);
  }

  install(type: SceneryAssetType, container: AssetContainer): void {
    if (this.disposed || this.installed.has(type)) return;
    const staged: InstalledModel[] = [];
    try {
      for (const placement of this.placements.get(type) ?? []) {
        if (![placement.width, placement.depth, placement.height].every(value => Number.isFinite(value) && value > 0)
          || !Number.isFinite(placement.floor) || (placement.rotation !== undefined && !Number.isFinite(placement.rotation))
          || (placement.footprintRadius !== undefined && (!Number.isFinite(placement.footprintRadius) || placement.footprintRadius <= 0))) throw new Error(`Invalid island placement: ${type}`);
        const instance = container.instantiateModelsToScene(name => `${type}-${name}`, false, { doNotInstantiate: false });
        const pivot = new TransformNode(`${type}-artwork`, this.scene);
        staged.push({ instance, pivot });
        const normalized = new TransformNode(`${type}-normalized`, this.scene);
        const oriented = new TransformNode(`${type}-orientation`, this.scene);
        normalized.parent = pivot; oriented.parent = normalized;
        for (const node of instance.rootNodes) node.parent = oriented;
        normalized.computeWorldMatrix(true);
        for (const mesh of normalized.getChildMeshes()) mesh.computeWorldMatrix(true);
        let bounds = normalized.getHierarchyBoundingVectors(true);
        if (type === 'scenery_red_line' && bounds.max.x - bounds.min.x > bounds.max.z - bounds.min.z) {
          oriented.rotation.y = Math.PI / 2;
          oriented.computeWorldMatrix(true);
          for (const mesh of normalized.getChildMeshes()) mesh.computeWorldMatrix(true);
          bounds = normalized.getHierarchyBoundingVectors(true);
        }
        const x = bounds.max.x - bounds.min.x, y = bounds.max.y - bounds.min.y, z = bounds.max.z - bounds.min.z;
        if (![x, y, z].every(value => Number.isFinite(value) && value > 0.0001)) throw new Error(`Invalid island geometry: ${type}`);
        // Slight oval shaping follows the water shader's shore contour. Height
        // stays proportional, capped so masts and sky islands remain readable.
        let sx = placement.width / x, sz = placement.depth / z;
        const sy = Math.min(Math.max(sx, sz), placement.height / y);
        if (placement.footprintRadius !== undefined) {
          // Bounding rectangles alone can hide protruding rocks at the corners.
          // Scan imported vertices once, in the oriented model's coordinates,
          // and shrink only X/Z when necessary to preserve the navigation disk.
          let maximumRadius = 0;
          const point = new Vector3(), transformed = new Vector3();
          const centerX = (bounds.min.x + bounds.max.x) / 2, centerZ = (bounds.min.z + bounds.max.z) / 2;
          for (const mesh of normalized.getChildMeshes()) {
            const positions = mesh.getVerticesData(VertexBuffer.PositionKind);
            if (!positions && mesh.getTotalVertices()) maximumRadius = Math.max(maximumRadius, Math.hypot(placement.width / 2, placement.depth / 2));
            if (!positions) continue;
            const matrix = mesh.getWorldMatrix();
            for (let index = 0; index < positions.length; index += 3) {
              point.set(positions[index], positions[index + 1], positions[index + 2]);
              Vector3.TransformCoordinatesToRef(point, matrix, transformed);
              maximumRadius = Math.max(maximumRadius, Math.hypot((transformed.x - centerX) * sx, (transformed.z - centerZ) * sz));
            }
          }
          const correction = maximumRadius > placement.footprintRadius ? placement.footprintRadius / maximumRadius : 1;
          sx *= correction; sz *= correction;
        }
        normalized.scaling.set(sx, sy, sz);
        normalized.position.set(-(bounds.min.x + bounds.max.x) * sx / 2, -bounds.min.y * sy, -(bounds.min.z + bounds.max.z) * sz / 2);
        pivot.parent = placement.parent;
        pivot.position.y = placement.floor;
        pivot.rotation.y = placement.rotation ?? 0;
        for (const mesh of pivot.getChildMeshes()) {
          mesh.isPickable = Boolean(placement.interactionID);
          if (placement.interactionID) mesh.metadata = { ...mesh.metadata, creatureID: placement.interactionID };
          (mesh instanceof InstancedMesh ? mesh.sourceMesh : mesh).receiveShadows = true;
          // Static imported Mesh and InstancedMesh both inherit these methods.
          mesh.computeWorldMatrix(true);
          if (!placement.animated) mesh.freezeWorldMatrix();
          this.shadow.addShadowCaster(mesh, false);
        }
        for (const animation of instance.animationGroups) animation.stop();
      }
    } catch (error) {
      this.release(staged);
      throw error;
    }
    this.instances.push(...staged);
    this.installed.add(type);
    if (type === 'creature_zunesha') {
      const materials = new Set<PBRMaterial>();
      for (const mesh of container.meshes) {
        if (!mesh.getTotalVertices() || !(mesh.material instanceof PBRMaterial) || materials.has(mesh.material)) continue;
        materials.add(mesh.material);
        const box = mesh.getBoundingInfo().boundingBox;
        this.elephantStrides.push(new ZuneshaStride(mesh.material, box.minimum.clone(), box.maximum.subtract(box.minimum)));
      }
    }
    if (type === 'scenery_reverse_mountain' || type === 'island_water_seven') {
      for (const material of container.materials) {
        if (material instanceof PBRMaterial) this.waterfallFlows.push(new WaterfallFlow(material));
      }
    }
  }

  update(elapsed: number, reducedMotion: boolean): void {
    for (const flow of this.waterfallFlows) flow.update(elapsed, reducedMotion);
    for (const stride of this.elephantStrides) stride.update(elapsed, reducedMotion);
  }

  private release(entries: readonly InstalledModel[]): void {
    for (const { instance, pivot } of entries) {
      for (const mesh of pivot.getChildMeshes()) this.shadow.removeShadowCaster(mesh, false);
      instance.dispose(); pivot.dispose();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.release(this.instances);
    this.instances = []; this.placements.clear(); this.installed.clear();
    // Materials and their plugins are owned and disposed by the asset container.
    this.waterfallFlows = []; this.elephantStrides = [];
  }
}
