import { components } from "./_generated/api";
import { identifyAppUser } from "./identity";
import { exposeTaxiXpress, taxiXpressApp } from "../apps/taxi-xpress/host";

// Public functions of the Taxi Xpress driver app, called as taxiXpress:<name>.
export const {
  enroll, begin, publish, heartbeat, end, mine,
  canManage, listForApproval, setApprovalByOperator,
} = exposeTaxiXpress(components.taxiXpress, identifyAppUser(taxiXpressApp));
