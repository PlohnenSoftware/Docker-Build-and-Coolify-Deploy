# Smallest thing that still proves the plumbing: a build arg reaches the build,
# a stage can be targeted, and the result is a runnable image.
FROM alpine:3.22 AS base
ARG GREETING=unset
RUN printf '%s\n' "$GREETING" > /greeting

FROM base AS final
CMD ["cat", "/greeting"]
