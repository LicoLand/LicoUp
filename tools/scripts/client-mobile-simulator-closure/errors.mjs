export class ClosureError extends Error {
  constructor(category) {
    super(category);
    this.category = category;
  }
}

export function requireValue(condition, category) {
  if (!condition) throw new ClosureError(category);
}

export function runClosureStage(category, action) {
  try {
    return action();
  } catch (error) {
    if (error instanceof ClosureError) throw error;
    throw new ClosureError(category);
  }
}
