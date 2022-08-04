import { default as reducer, setVariant } from "../src/components/resource-list/VariantSlice";

describe("VariantSlice", () => {
  it("sets variant", () => {
    const type = "Feature";
    const name = "abc";
    const variant = "v1";
    const payload = { type, name, variant };
    const action = setVariant(payload);
    const newState = reducer(undefined, action);
    expect(newState).toMatchObject({ [type]: { [name]: variant } });
  });
});
