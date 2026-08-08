export class ReceiptValidationError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}
