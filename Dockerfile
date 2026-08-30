# syntax=docker/dockerfile:1

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Targeted patch of the two OpenSSL packages known to need it, rather than
# a blanket `apk upgrade` - smaller blast radius, same effect for this CVE.
RUN apk upgrade --no-cache libcrypto3 libssl3

# The npm CLI bundled in the base image is unused at runtime (we only ever
# run `node app.js`), but its own vendored dependencies (tar, pacote,
# sigstore, ...) routinely trip vulnerability scanners. Remove it entirely.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

# Run as a non-root, unprivileged user (defense in depth for DevSecOps requirements)
RUN addgroup -S app && adduser -S app -G app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json app.js ./

USER app
EXPOSE 8080

CMD ["node", "app.js"]
