// Better Plan's cubic connector uses fixed side-center ports and horizontal
// endpoint tangents. Longer routes preserve obstacle lanes with smooth splines.
const mix = (a, b, t) => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
const quadratic = (a, b, c, t) => mix(mix(a, b, t), mix(b, c, t), t);
const cubic = (a, b, c, d, t) => mix(quadratic(a, b, c, t), quadratic(b, c, d, t), t);
const ports = (source, target) => [{ x: source.x + source.width / 2, y: source.y }, { x: target.x - target.width / 2, y: target.y }];
const controls = (start, end) => {
  const bend = Math.max(24, (end.x - start.x) / 2);
  return [{ x: start.x + bend, y: start.y }, { x: end.x - bend, y: end.y }];
};

export function cubicConnector(source, target) {
  const [start, end] = ports(source, target);
  const [a, b] = controls(start, end);
  return { path: `M${start.x},${start.y} C${a.x},${a.y} ${b.x},${b.y} ${end.x},${end.y}`, ...cubic(start, a, b, end, 0.5) };
}

export function routedConnector(source, target, layout, nodes) {
  const [start, end] = ports(source, target);
  const [a, b] = controls(start, end);
  if (target.x > source.x) {
    const obstacles = nodes.filter((node) => node.code !== source.code && node.code !== target.code && node.x > source.x && node.x < target.x);
    const clear = Array.from({ length: 39 }, (_, index) => cubic(start, a, b, end, (index + 1) / 40)).every((point) =>
      !obstacles.some((node) => Math.abs(point.x - node.x) < node.width / 2 + 14 && Math.abs(point.y - node.y) < node.height / 2 + 14));
    if (clear) return cubicConnector(source, target);
  }
  const route = [start, { x: start.x + 24, y: start.y }];
  if (source.code === target.code) {
    const top = Math.min(...layout.points.map((point) => point.y), source.y - source.height / 2 - 55);
    route.push({ x: start.x + 55, y: top }, { x: end.x - 55, y: top });
  } else {
    route.push(...layout.points.slice(1, -1));
  }
  route.push({ x: end.x - 24, y: end.y }, end);
  // Adjacent quadratic segments share a tangent. Fixed endpoint controls keep
  // arrows normal to the boundary; labels are projected onto the actual curve.
  let path = `M${start.x},${start.y}`, previous = start;
  let closest = { x: layout.x, y: layout.y }, distance = Infinity;
  for (let index = 1; index < route.length - 1; index++) {
    const control = route[index], next = route[index + 1];
    const endpoint = index === route.length - 2 ? next : mix(control, next, 0.5);
    path += ` Q${control.x},${control.y} ${endpoint.x},${endpoint.y}`;
    if (Number.isFinite(layout.x)) for (let step = 0; step <= 20; step++) {
      const point = quadratic(previous, control, endpoint, step / 20);
      const squared = (point.x - layout.x) ** 2 + (point.y - layout.y) ** 2;
      if (squared < distance) { closest = point; distance = squared; }
    }
    previous = endpoint;
  }
  return { path, ...closest };
}
