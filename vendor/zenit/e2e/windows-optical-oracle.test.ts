import { expect, test } from "bun:test";
import { circleRay, snellDisplacement } from "./windows-optical-oracle";

test("Snell displacement uses the difference of ray angles", () => {
  // 45-degree incident ray: Snell gives asin(sin(pi/4)/1.45).
  const transmitted = Math.asin(Math.SQRT1_2 / 1.45);
  const expected = 10 * Math.tan(Math.PI/4 - transmitted);
  expect(snellDisplacement(1, 1, 10, 10, 1.45)).toBeCloseTo(expected, 10);
});
test("grazing Snell rays have bounded finite displacement", () => {
  const ior = 1.45;
  const limit = 10 * Math.sqrt(ior*ior-1);
  const displacement = snellDisplacement(1000000, 1, 10, 10, ior);
  expect(displacement).toBeLessThan(limit);
  expect(displacement).toBeCloseTo(limit, 3);
});
test("circle over a flat exit plane predicts the independently captured ramp pixel", () => {
  // The 1x fixture's pixel center is (3.5,40.5). The captured hardware
  // pixel is 210/211/211; keep its original four-level pixel tolerance.
  const expected = [210,211,211];
  circleRay(3.5,40.5,1).forEach((channel,i) => expect(Math.abs(channel-expected[i])).toBeLessThanOrEqual(4));
});
