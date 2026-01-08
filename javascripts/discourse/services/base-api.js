import Service, { service } from "@ember/service";
import KeyValueStore from "discourse/lib/key-value-store";
import { AaveFetcher } from "../lib/api/aave-fetcher";
import { SnapshotFetcher } from "../lib/api/snapshot-fetcher";
import { TallyFetcher } from "../lib/api/tally-fetcher";
import { SHORT_CACHE_TTL_MS } from "../lib/constants.js";

const cacheContext = "gov-proposal-";
const persistentCache = new KeyValueStore(cacheContext);

export default class BaseApiService extends Service {
  @service mapCache;

  loading = new Map();
  promises = new Map();

  constructor() {
    super(...arguments);

    this.snapshot = new SnapshotFetcher(this);
    this.aave = new AaveFetcher(this);
    this.tally = new TallyFetcher(this);
  }

  async fetchWithCache(
    cacheKey,
    fetchFn,
    { ttl = SHORT_CACHE_TTL_MS, ignoreCache = false } = {}
  ) {
    if (!ignoreCache) {
      const cached = this.mapCache.get(cacheKey);
      if (cached) {
        return Promise.resolve(cached);
      }
    }

    if (this.loading.get(cacheKey)) {
      return this.promises.get(cacheKey);
    }

    this.loading.set(cacheKey, true);
    const promise = this._executeAndCache(cacheKey, fetchFn, ttl);
    this.promises.set(cacheKey, promise);

    return promise;
  }

  async _executeAndCache(cacheKey, fetchFn, ttl) {
    try {
      const data = await fetchFn();
      if (ttl > 0) {
        this.mapCache.set(cacheKey, data, ttl);
      }
      return data;
    } catch (error) {
      console.error(`Fetch error for ${cacheKey}:`, error);
      throw error;
    } finally {
      this.loading.set(cacheKey, false);
    }
  }

  setPersistentCache({ type, id, topicId }, data) {
    const cacheKey = `${type}-${id}-${topicId}`;
    try {
      persistentCache.setObject({ key: cacheKey, value: data });
      persistentCache.setItem(
        cacheKey + ":expires",
        Date.now() + 30 * 24 * 60 * 60 * 1000
      ); // 30 days
    } catch {
      console.info(`Failed to set persistent cache for ${cacheKey}`);
    }
  }

  getPersistentCache({ type, id, topicId }) {
    const cacheKey = `${type}-${id}-${topicId}`;

    try {
      const expires = persistentCache.getInt(cacheKey + ":expires");

      if (expires && Date.now() > expires) {
        persistentCache.remove(cacheKey);
        persistentCache.remove(cacheKey + ":expires");
        return null;
      }

      return persistentCache.getObject(cacheKey);
    } catch {
      return null;
    }
  }

  findPersistentCache({ type, topicId }) {
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (
          key.startsWith(`${cacheContext}${type}-`) &&
          key.endsWith(`-${topicId}`)
        ) {
          const id = key.slice(
            `${cacheContext}${type}-`.length,
            key.length - `-${topicId}`.length
          );

          const proposal = this.getPersistentCache({ type, id, topicId });

          if (proposal) {
            return proposal;
          }
        }
      }
    } catch {}

    return null;
  }
}
