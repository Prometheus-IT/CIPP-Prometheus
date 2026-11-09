import { Layout as DashboardLayout } from '../../../../layouts/index'
import { AzureReportPage } from '../../../../custom/azure/azure-report-page'

const Page = () => <AzureReportPage kind="Retirements" />
Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>
export default Page
