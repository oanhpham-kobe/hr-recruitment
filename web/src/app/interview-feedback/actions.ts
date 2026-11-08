"use server";
import { revalidatePath } from "next/cache";
import type {
  ConsolidationInput,
  CreateInput,
  PublishInput,
  ResponseInput,
} from "@/lib/interview-feedback/model";
import {
  createFeedbackCollection,
  loadFeedbackCollection,
  loadFeedbackInvitation,
  loadFeedbackWorkspace,
  publishFeedbackTemplate,
  revokeFeedbackInvitation,
  saveFeedbackConsolidation,
  saveFeedbackResponse,
} from "@/lib/interview-feedback/server";
export async function workspaceAction(offset = 0) {
  return loadFeedbackWorkspace(offset);
}
export async function collectionAction(id: string) {
  return loadFeedbackCollection(id);
}
export async function invitationAction(id: string) {
  return loadFeedbackInvitation(id);
}
export async function publishAction(input: PublishInput) {
  const result = await publishFeedbackTemplate(input);
  if (result.success) revalidatePath("/interview-feedback");
  return result;
}
export async function createAction(input: CreateInput) {
  const result = await createFeedbackCollection(input);
  if (result.success) revalidatePath("/interview-feedback");
  return result;
}
export async function respondAction(input: ResponseInput) {
  const result = await saveFeedbackResponse(input);
  if (result.success) {
    revalidatePath("/interview-feedback");
    revalidatePath(`/interview-feedback/${input.invitationId}`);
  }
  return result;
}
export async function revokeAction(input: {
  invitationId: string;
  expectedVersionNo: number;
}) {
  const result = await revokeFeedbackInvitation(input);
  if (result.success) revalidatePath("/interview-feedback");
  return result;
}
export async function consolidateAction(input: ConsolidationInput) {
  const result = await saveFeedbackConsolidation(input);
  if (result.success) revalidatePath("/interview-feedback");
  return result;
}
